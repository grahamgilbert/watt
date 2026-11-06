import XCTest
import Security
import WattEnergyProtocol

final class EnergyImpactParserTests:XCTestCase {
    private let start=Date(timeIntervalSince1970:1_800_000_000)
    private var end:Date {start.addingTimeInterval(1)}
    private func data(_ root:[String:Any]) throws -> Data {try PropertyListSerialization.data(fromPropertyList:root,format:.xml,options:0)}
    private func sample(task:EnergyImpactTask?=nil)->EnergyImpactSample {
        EnergyImpactSample(startedAt:start,endedAt:end,tasks:[task ?? EnergyImpactTask(pid:42,name:"build",energyImpact:1.5,energyImpactPerSecond:1.5,processStartMicroseconds:1_799_999_900_000_000)])
    }
    func testReferencePowermetricsOutputSkipsDeadTasksAggregate() throws {
        let path=try XCTUnwrap(Bundle.module.url(forResource:"powermetrics-tasks-reference",withExtension:"plist",subdirectory:"Fixtures"))
        let parsed=try EnergyImpactParser.parse(Data(contentsOf:path)+Data([0]),startedAt:start,endedAt:end)
        XCTAssertEqual(parsed.tasks.map(\.pid),[1234,5678])
        XCTAssertEqual(parsed.tasks.map(\.name),["Safari","Chrome"])
        XCTAssertEqual(parsed.tasks[0].energyImpact,125.5)
        XCTAssertEqual(parsed.tasks[1].energyImpactPerSecond,25.075)
    }
    func testUnknownRelationshipSentinelsStayUnavailableWithoutDroppingRealTasks() throws {
        let output=try data(["tasks":[["pid":42,"name":"build","energy_impact":1.0,"responsible_pid":-1,"parent_pid":-1],
                                      ["pid":-1,"name":"DEAD_TASKS","energy_impact":5.0]]])
        let parsed=try EnergyImpactParser.parse(output,startedAt:start,endedAt:end)
        XCTAssertEqual(parsed.tasks.count,1)
        XCTAssertNil(parsed.tasks[0].responsiblePID);XCTAssertNil(parsed.tasks[0].parentPID)
        XCTAssertThrowsError(try EnergyImpactParser.parse(data(["tasks":[["pid":-1,"name":"unexpected"]]]),startedAt:start,endedAt:end))
    }
    func testNulSeparatedMetadataAndSamplesSelectTheLatestTaskPlist() throws {
        let metadata=try data(["machine_name":"test"])
        let first=try data(["tasks":[["pid":42,"name":"build","energy_impact":1.5,"energy_impact_per_s":1.5]]])
        let last=try data(["tasks":[["pid":42,"name":"build","energy_impact":2.5,"energy_impact_per_s":2.5,"responsible_pid":10,"ppid":12]]])
        let output=metadata+Data([0])+first+Data([0])+last+Data([0])
        let parsed=try EnergyImpactParser.parse(output,startedAt:start,endedAt:end)
        XCTAssertEqual(parsed.tasks.count,1);XCTAssertEqual(parsed.tasks[0].energyImpactPerSecond,2.5)
        XCTAssertEqual(parsed.tasks[0].responsiblePID,10);XCTAssertEqual(parsed.tasks[0].parentPID,12)
        XCTAssertNil(parsed.tasks[0].processStartMicroseconds)
    }
    func testAbsentMeasurementsStayUnavailableAndSupportedZeroStaysZero() throws {
        let missing=try EnergyImpactParser.parse(data(["tasks":[["pid":42,"name":"build"]]]),startedAt:start,endedAt:end)
        XCTAssertNil(missing.tasks[0].energyImpact);XCTAssertFalse(missing.hasEnergyValues)
        let zero=try EnergyImpactParser.parse(data(["tasks":[["pid":0,"name":"kernel_task","energy_impact":0.0,"energy_impact_per_s":0.0]]]),startedAt:start,endedAt:end)
        XCTAssertEqual(zero.tasks[0].energyImpactPerSecond,0);XCTAssertTrue(zero.hasEnergyValues)
    }
    func testNegativeBooleanAndFractionalPIDMeasurementsAreRejected() throws {
        for value:Any in [-1.0,true,"1.0"] {
            XCTAssertThrowsError(try EnergyImpactParser.parse(data(["tasks":[["pid":42,"name":"build","energy_impact":value]]]),startedAt:start,endedAt:end))
        }
        XCTAssertThrowsError(try EnergyImpactParser.parse(data(["tasks":[["pid":42.5,"name":"build"]]]),startedAt:start,endedAt:end))
        XCTAssertThrowsError(try sample(task:EnergyImpactTask(pid:42,name:"build",energyImpact:.nan,energyImpactPerSecond:nil)).validate())
        XCTAssertThrowsError(try sample(task:EnergyImpactTask(pid:42,name:"build",energyImpact:nil,energyImpactPerSecond:.infinity)).validate())
    }
    func testDuplicatePIDsAndMalformedOrOversizedOutputAreRejected() throws {
        let task:[String:Any]=["pid":42,"name":"build","energy_impact":1.0]
        XCTAssertThrowsError(try EnergyImpactParser.parse(data(["tasks":[task,task]]),startedAt:start,endedAt:end))
        XCTAssertThrowsError(try EnergyImpactParser.parse(Data("garbage".utf8),startedAt:start,endedAt:end))
        XCTAssertThrowsError(try EnergyImpactParser.parse(Data(repeating:0,count:EnergyServiceConfiguration.maximumOutputBytes+1),startedAt:start,endedAt:end))
    }
    func testSelectionRejectsFutureStaleAndReusedPIDCaptures() {
        let value=sample()
        let processStart=start.addingTimeInterval(-100)
        XCTAssertNotNil(value.task(forPID:42,processStart:processStart,at:end))
        XCTAssertNil(value.task(forPID:42,processStart:nil,at:end))
        XCTAssertNil(value.task(forPID:42,processStart:start.addingTimeInterval(0.5),at:end))
        XCTAssertNil(value.task(forPID:42,processStart:processStart.addingTimeInterval(-1),at:end))
        XCTAssertNil(value.task(forPID:42,processStart:processStart,at:start))
        XCTAssertNil(value.task(forPID:42,processStart:processStart,at:end.addingTimeInterval(6)))
        XCTAssertNil(value.task(forPID:43,processStart:processStart,at:end))
    }
    func testDecodedCaptureRebuildsLookupWithoutChangingPersistedSchema() throws {
        let original=sample()
        let encoded=try JSONEncoder().encode(original)
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        XCTAssertEqual(Set(object.keys),["id","startedAt","endedAt","tasks"])
        let decoded=try JSONDecoder().decode(EnergyImpactSample.self,from:encoded)
        XCTAssertEqual(decoded.task(forPID:42,processStart:start.addingTimeInterval(-100),at:end)?.energyImpactPerSecond,1.5)
        XCTAssertNil(decoded.task(forPID:42,processStart:start.addingTimeInterval(-99),at:end))
        XCTAssertNil(decoded.task(forPID:43,processStart:start.addingTimeInterval(-100),at:end))
    }
    func testCacheBoundsAgeAndClearsInvalidMeasurements() {
        let cache=EnergyImpactCache();cache.store(sample())
        XCTAssertNotNil(cache.latest(maxAge:5,now:end.addingTimeInterval(5)))
        XCTAssertNil(cache.latest(maxAge:5,now:end.addingTimeInterval(5.1)))
        XCTAssertNil(cache.latest(maxAge:5,now:start))
        cache.store(sample(task:EnergyImpactTask(pid:42,name:"build",energyImpact:-1,energyImpactPerSecond:nil)))
        XCTAssertNil(cache.latest(maxAge:5,now:end))
    }
    func testProcessStartMetadataIsOptionalForOldSamplesButValidatedWhenPresent() throws {
        let encoded=try JSONEncoder().encode(sample())
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        var tasks=try XCTUnwrap(object["tasks"] as? [[String:Any]])
        tasks[0].removeValue(forKey:"processStartMicroseconds");object["tasks"]=tasks
        let old=try JSONDecoder().decode(EnergyImpactSample.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertNil(old.tasks[0].processStartMicroseconds);XCTAssertNoThrow(try old.validate())
        XCTAssertThrowsError(try sample(task:EnergyImpactTask(pid:42,name:"build",energyImpact:1,energyImpactPerSecond:1,processStartMicroseconds:1_800_000_000_500_000)).validate())
    }
    func testConnectionRequirementsPinDeveloperIDBundleAndTeam() {
        let string=EnergyServiceIdentity.requirementString(identifier:EnergyServiceConfiguration.appIdentifier,team:"ABCDEFGHIJ")
        XCTAssertTrue(string.contains("identifier \"com.grahamgilbert.Watt\""))
        XCTAssertTrue(string.contains("subject.OU"));XCTAssertTrue(string.contains("100.6.1.13"))
        var requirement:SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(string as CFString,[],&requirement),errSecSuccess)
    }
}
