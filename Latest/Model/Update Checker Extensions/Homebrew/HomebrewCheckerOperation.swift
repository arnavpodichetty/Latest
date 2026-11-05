//
//  HomebrewCheckerOperation.swift
//  Latest
//
//  Created by Max Langer on 12.03.22.
//  Copyright © 2022 Max Langer. All rights reserved.
//

import Cocoa

/// The operation for checking for updates via Homebrew.
class HomebrewCheckerOperation: StatefulOperation, UpdateCheckerOperation, @unchecked Sendable {
	
	static var sourceType: App.Source {
		return .none
	}
	
	/// The bundle to be checked for updates.
	private let bundle: App.Bundle
	
	/// The update fetched during the checking operation.
	fileprivate var update: App.Update?
	
	private let repository: UpdateRepository?
	
	static func canPerformUpdateCheck(forAppAt url: URL) -> Bool {
		return true
	}
		
	required init(with bundle: App.Bundle, repository: UpdateRepository?, completionBlock: @escaping UpdateCheckerCompletionBlock) {
		self.bundle =  bundle
		self.repository = repository
		
		super.init()
		
		self.completionBlock = {
			if let update = self.update {
				completionBlock(.success(update))
			} else {
				completionBlock(.failure(self.error ?? LatestError.updateInfoUnavailable))
			}
		}
	}
	
	
	// MARK: - Operation

	override func execute() {
		guard let repository else {
			self.finish()
			return
		}
		
		repository.updateInfo(for: bundle) { bundle, version, minimumOSVersion, caskToken in
			defer { self.finish() }
			guard let version else { return }

			// Fork change: if Homebrew is installed, update the app through `brew` instead of just opening it.
			let action: App.Update.Action
			if let caskToken, HomebrewUpdateOperation.brewURL != nil {
				action = .builtIn(block: { app in
					UpdateQueue.shared.addOperation(HomebrewUpdateOperation(bundleIdentifier: app.bundleIdentifier, appIdentifier: app.identifier, caskToken: caskToken, appURL: app.fileURL))
				})
			} else {
				action = .external(label: bundle.name, block: { app in
					app.open()
				})
			}

			self.update = App.Update(app: bundle, remoteVersion: version, minimumOSVersion: minimumOSVersion, source: .homebrew, date: nil, releaseNotes: nil, updateAction: action)
		}
	}

}


// MARK: - Homebrew Updater (fork addition)

/// Updates an app by running Homebrew.
///
/// If Homebrew already manages the app, this runs `brew upgrade --cask --greedy <token>`.
/// Otherwise it runs `brew install --cask --force <token>` into the folder the app already lives in. This replaces the
/// existing copy with the newest version (app data in ~/Library is untouched) and makes Homebrew manage the app from then on.
class HomebrewUpdateOperation: UpdateOperation, @unchecked Sendable {

	/// Errors specific to Homebrew updates.
	enum HomebrewError: LocalizedError {
		case notInstalled
		case appStillRunning(name: String)
		case commandFailed(output: String)

		var errorDescription: String? {
			switch self {
			case .notInstalled:
				return "Homebrew is not installed. Install it from brew.sh."
			case .appStillRunning(let name):
				return "\(name) did not quit. Quit it and try again."
			case .commandFailed(let output):
				// Show the last few lines, which usually contain the actual error.
				let tail = output.split(separator: "\n").suffix(6).joined(separator: "\n")
				return "Homebrew could not update this app.\n\n\(tail)"
			}
		}
	}

	/// Makes sure only one brew update runs at a time.
	private static let brewLock = DispatchSemaphore(value: 1)

	/// Location of the brew executable (Apple silicon first, then Intel). Apps launched from Finder don't inherit the shell PATH.
	static var brewURL: URL? {
		["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
			.map { URL(fileURLWithPath: $0) }
			.first { FileManager.default.isExecutableFile(atPath: $0.path) }
	}

	/// The Homebrew cask name, e.g. "google-chrome".
	private let caskToken: String

	/// Where the app lives, used for the install folder and to relaunch it afterwards.
	private let appURL: URL

	/// The currently running brew process, kept so it can be cancelled.
	private var process: Process?
	private let processLock = NSLock()
	
	/// Whether cancelling may stop the running brew process. Turned off once brew starts replacing the app.
	private var canTerminateProcess = true

	init(bundleIdentifier: String, appIdentifier: App.Bundle.Identifier, caskToken: String, appURL: URL) {
		self.caskToken = caskToken
		self.appURL = appURL
		super.init(bundleIdentifier: bundleIdentifier, appIdentifier: appIdentifier)
	}


	// MARK: - Operation Overrides

	override func execute() {
		super.execute()

		guard let brew = Self.brewURL else {
			self.finish(with: HomebrewError.notInstalled)
			return
		}

		DispatchQueue.global(qos: .userInitiated).async {
			// Run one brew update at a time. "Update All" starts several updates at once, and parallel brew runs can clash on Homebrew's locks.
			self.progressState = .pending
			Self.brewLock.wait()
			defer { Self.brewLock.signal() }
			guard !self.isCancelled else { return self.finish() }

			do {
				// Is the app already managed by Homebrew?
				let isManaged = try self.run(brew, ["list", "--cask", self.caskToken]).status == 0
				guard !self.isCancelled else { return self.finish() }
				
				// Quit the app right before replacing it, so it isn't closed for nothing if the check above fails.
				self.progressState = .installing
				guard let wasRunning = self.quitAppIfRunning() else {
					self.finish(with: HomebrewError.appStillRunning(name: self.appURL.deletingPathExtension().lastPathComponent))
					return
				}
				
				// Reopen the app afterwards if it was open, whether or not the update worked.
				defer {
					if wasRunning {
						NSWorkspace.shared.openApplication(at: self.appURL, configuration: NSWorkspace.OpenConfiguration())
					}
				}
				guard !self.isCancelled else { return self.finish() }
				
				let arguments = isManaged
					? ["upgrade", "--cask", "--greedy", self.caskToken]
					: ["install", "--cask", "--force", "--appdir=\(self.appURL.deletingLastPathComponent().path)", self.caskToken]
				
				// From here on, cancelling no longer stops brew: stopping it halfway could leave the app deleted.
				self.processLock.withCriticalScope { self.canTerminateProcess = false }
				
				let result = try self.run(brew, arguments)
				guard result.status == 0 else {
					self.finish(with: HomebrewError.commandFailed(output: result.output))
					return
				}
				
				self.finish()
			} catch {
				self.finish(with: error)
			}
		}
	}
	
	override func cancel() {
		processLock.withCriticalScope {
			if canTerminateProcess { process?.terminate() }
		}
		super.cancel()
	}
	
	
	// MARK: - Helpers

	/// Runs brew with the given arguments and returns its exit status and combined output.
	private func run(_ brew: URL, _ arguments: [String]) throws -> (status: Int32, output: String) {
		let process = Process()
		process.executableURL = brew
		process.arguments = arguments

		var environment = ProcessInfo.processInfo.environment
		environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
		environment["HOMEBREW_NO_ENV_HINTS"] = "1"
		environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
		process.environment = environment

		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = pipe
		process.standardInput = FileHandle.nullDevice

		try process.run()
		processLock.withCriticalScope { self.process = process }

		// Read before waiting so a full pipe can't deadlock the process.
		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		processLock.withCriticalScope { self.process = nil }

		return (process.terminationStatus, String(decoding: data, as: UTF8.self))
	}

	/// Quits the app before replacing it.
	/// Returns whether it was running, or `nil` if it did not quit in time (e.g. an unsaved-changes prompt).
	private func quitAppIfRunning() -> Bool? {
		let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
		guard !running.isEmpty else { return false }

		running.forEach { $0.terminate() }

		// Give the app up to 15 seconds to quit.
		let deadline = Date().addingTimeInterval(15)
		while running.contains(where: { !$0.isTerminated }) && Date() < deadline {
			Thread.sleep(forTimeInterval: 0.25)
		}

		return running.contains(where: { !$0.isTerminated }) ? nil : true
	}

}
