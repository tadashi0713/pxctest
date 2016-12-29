//
//  RunTestsWorker.swift
//  pxctest
//
//  Created by Johannes Plunien on 29/12/2016.
//  Copyright © 2016 Johannes Plunien. All rights reserved.
//

import FBSimulatorControl
import Foundation

final class RunTestsWorker {

    let simulator: FBSimulator
    let target: FBXCTestRunTarget

    var configuration: FBSimulatorConfiguration {
        return simulator.configuration!
    }

    private(set) var errors: [RunTestsError] = []

    init(simulator: FBSimulator, target: FBXCTestRunTarget) {
        self.simulator = simulator
        self.target = target
    }

    func abortTestRun() throws {
        for application in target.applications {
            try simulator.killApplication(withBundleID: application.bundleID)
        }
    }

    func boot(context: BootContext) throws {
        try simulator.boot(context: context)
    }

    func extractDiagnostics(outputManager: RunTestsOutputManager) throws {
        for application in target.applications {
            guard let diagnostics = simulator.simulatorDiagnostics.launchedProcessLogs().first(where: { $0.0.processName == application.name })?.value else { continue }
            let destinationPath = outputManager.urlFor(worker: self).path
            try diagnostics.writeOut(toDirectory: destinationPath)
        }
        for error in errors {
            for crash in error.crashes {
                let destinationPath = outputManager.urlFor(worker: self).path
                try crash.writeOut(toDirectory: destinationPath)
            }
        }
    }

    func loadDefaults(context: DefaultsContext) throws {
        try simulator.loadDefaults(context: context)
    }

    func installApplications() throws {
        try simulator.install(applications: target.applications)
    }

    func overrideWatchDogTimer() throws {
        let applications = target.applications.map { $0.bundleID }
        try simulator.interact.overrideWatchDogTimer(forApplications: applications, withTimeout: 60.0).perform()
    }

    func startTests(context: RunTestsContext, reporters: RunTestsReporters) throws {
        let testsToRun = context.testsToRun[target.name] ?? Set<String>()
        let testEnvironment = Environment.prepare(forRunningTests: target.testLaunchConfiguration.testEnvironment, with: context.environment)
        let testLaunchConfigurartion = target.testLaunchConfiguration
            .withTestsToRun(target.testLaunchConfiguration.testsToRun.union(testsToRun))
            .withTestEnvironment(testEnvironment)

        let reporter = try reporters.addReporter(for: simulator, target: target)

        try simulator.interact.startTest(with: testLaunchConfigurartion, reporter: reporter).perform()
    }

    func waitForTestResult(timeout: TimeInterval) {
        let testManagerResults = simulator.resourceSink.testManagers.flatMap { $0.waitUntilTestingHasFinished(withTimeout: timeout) }
        if testManagerResults.reduce(true, { $0 && $1.didEndSuccessfully }) {
            return
        }
        errors.append(
            RunTestsError(
                simulator: simulator,
                target: target.name,
                errors: testManagerResults.flatMap { $0.error },
                crashes: testManagerResults.flatMap { $0.crashDiagnostic }
            )
        )
    }

}

extension Sequence where Iterator.Element == RunTestsWorker {

    func abortTestRun() throws {
        for worker in self {
            try worker.abortTestRun()
        }
    }

    func boot(context: BootContext) throws {
        for worker in self {
            try worker.boot(context: context)
        }
    }

    func installApplications() throws {
        for worker in self {
            try worker.installApplications()
        }
    }

    func loadDefaults(context: DefaultsContext) throws {
        for worker in self {
            try worker.loadDefaults(context: context)
        }
    }

    func overrideWatchDogTimer() throws {
        for worker in self {
            try worker.overrideWatchDogTimer()
        }
    }

    func startTests(context: RunTestsContext, reporters: RunTestsReporters) throws {
        for worker in self {
            try worker.startTests(context: context, reporters: reporters)
        }
    }

    func waitForTestResult(context: TestResultContext) throws -> [RunTestsError] {
        for worker in self {
            worker.waitForTestResult(timeout: context.timeout)
        }

        for worker in self {
            try worker.extractDiagnostics(outputManager: context.outputManager)
        }

        return flatMap { $0.errors }
    }

}