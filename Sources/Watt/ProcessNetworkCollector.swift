import Foundation
import Darwin

// One passive, fixed-command session for the recorder. There are no endpoint
// fields, DNS lookups, shell evaluation, or subprocess launches per refresh.
final class ProcessNetworkCollector:@unchecked Sendable {
    private let lock=NSLock()
    private var process:Process?
    private var output:FileHandle?
    private var session=UUID()
    private var parser=ProcessNetworkCSVParser()
    private var cadence:Double?
    private var latestRaw:ProcessNetworkRawCapture?
    private var latest:ProcessNetworkSample?
    private var identities=ProcessNetworkIdentityCache()
    private var failure:String?
    private var retryAfter:Date?
    private var launchedAt:Date?
    private var stopped=false
    static let executable="/usr/bin/nettop"
    // Read-only diagnostics also let integration tests prove this exact child
    // has exited before trusting its reaped RUSAGE_CHILDREN CPU accounting.
    var childProcessIdentifier:Int32? {
        lock.lock();defer {lock.unlock()}
        guard let process,process.isRunning else {return nil}
        return process.processIdentifier
    }
    static func arguments(cadence:Double)->[String] {
        ["-P","-L","0","-d","-s",String(Int(max(2,min(60,cadence.rounded())))),"-n","-x","-t","external","-J","bytes_in,bytes_out"]
    }
    deinit {stop()}

    func sample(processes:[ProcessRow],cadence requested:Double)->ProcessNetworkSample {
        let now=Date(),interval=max(2,min(60,requested.isFinite ? requested.rounded() : 5))
        lock.lock()
        guard !stopped else {
            let value=status(at:now,message:"Process network collection is stopped.",state:.unavailable)
            lock.unlock();return value
        }
        var old:Process?,oldOutput:FileHandle?
        if cadence != interval {
            old=process;oldOutput=output;process=nil;output=nil;session=UUID()
            latestRaw=nil;latest=nil;failure=nil;retryAfter=nil;identities.reset()
            parser=ProcessNetworkCSVParser();cadence=interval;launchedAt=nil
        }
        if process != nil,let lastProgress=latestRaw?.endedAt ?? launchedAt,
           now.timeIntervalSince(lastProgress)>max(30,interval*4) {
            old=process;oldOutput=output;process=nil;output=nil;session=UUID()
            latestRaw=nil;latest=nil;launchedAt=nil
            failure="Process network collection stopped responding. Collection will retry."
            retryAfter=now.addingTimeInterval(30);parser=ProcessNetworkCSVParser()
        }
        identities.observe(processes,at:now,cadence:interval)
        let shouldStart=process==nil && (retryAfter.map {now >= $0} ?? true)
        lock.unlock()
        Self.terminate(old,handle:oldOutput)
        if shouldStart {start(cadence:interval)}
        lock.lock();defer {lock.unlock()}
        if let raw=latestRaw,latest?.id != raw.id {latest=identities.resolve(raw)}
        if let latest,latest.isFresh(at:now) {return latest}
        let message=failure ?? (latest != nil ? "Process network capture is stale." : "Waiting for complete process network intervals…")
        return status(at:now,message:message,state:failure == nil && latest == nil ? .waiting : .unavailable)
    }

    private func status(at time:Date,message:String,state:ProcessNetworkStatus)->ProcessNetworkSample {
        ProcessNetworkSample(id:"\(session.uuidString):status",startedAt:time,endedAt:time,elapsed:0,tasks:[],
                             status:state,source:"nettop-external-tcp-udp",unmatchedProcesses:0,error:message)
    }

    func reset() {endSession(markStopped:false)}
    func stop() {endSession(markStopped:true)}

    private func start(cadence interval:Double) {
        guard FileManager.default.isExecutableFile(atPath:Self.executable) else {
            lock.lock();failure="This macOS installation does not provide process network collection.";retryAfter=Date().addingTimeInterval(300);lock.unlock();return
        }
        let value=Process(),token=UUID()
        let reader:FileHandle,writer:FileHandle
        do {(reader,writer)=try Self.terminalOutput()}
        catch {
            lock.lock();failure="Process network output could not be opened. Collection will retry."
            retryAfter=Date().addingTimeInterval(30);lock.unlock();return
        }
        value.executableURL=URL(fileURLWithPath:Self.executable);value.arguments=Self.arguments(cadence:interval)
        // nettop monitors terminal input even in logging mode when output is a
        // TTY. /dev/null is permanently readable at EOF and makes that dispatch
        // source spin. An idle raw terminal input has no readiness events.
        // Nothing writes to the master: this is not an interactive command API.
        value.standardInput=writer;value.standardOutput=writer;value.standardError=FileHandle.nullDevice
        value.qualityOfService = .utility
        lock.lock()
        guard process==nil,!stopped else {lock.unlock();return}
        session=token;parser=ProcessNetworkCSVParser(sessionID:token.uuidString);latestRaw=nil;latest=nil;failure=nil
        process=value;output=reader;cadence=interval;launchedAt=Date()
        let descriptor=reader.fileDescriptor
        reader.readabilityHandler={ [weak self] _ in
            self?.readable(descriptor,session:token,cadence:interval)
        }
        value.terminationHandler={ [weak self] process in self?.ended(token,status:process.terminationStatus) }
        // Hold the state lock across launch so a concurrent stop cannot miss a
        // not-yet-running child and then have it launched after cancellation.
        do {try value.run();lock.unlock();try? writer.close()}
        catch {
            process=nil;output=nil;session=UUID();launchedAt=nil;failure="Process network collection could not start. Collection will retry."
            retryAfter=Date().addingTimeInterval(30);lock.unlock()
            reader.readabilityHandler=nil
            try? reader.close();try? writer.close()
        }
    }

    // nettop's CSV is fully buffered on a pipe. A raw pseudo-terminal preserves
    // line buffering without interactive mode (-L is explicit), DNS, or endpoint
    // output. Nonblocking reads also make stop bounded and treat terminal EIO as
    // an ordinary stream closure rather than an NSFileHandle exception.
    private static func terminalOutput()throws->(FileHandle,FileHandle) {
        var master:Int32 = -1,slave:Int32 = -1
        var size=winsize(ws_row:24,ws_col:160,ws_xpixel:0,ws_ypixel:0)
        guard openpty(&master,&slave,nil,nil,&size)==0 else {throw POSIXError(.EIO)}
        do {
            var attributes=termios()
            guard tcgetattr(slave,&attributes)==0 else {throw POSIXError(.EIO)}
            cfmakeraw(&attributes)
            guard tcsetattr(slave,TCSANOW,&attributes)==0,
                  fcntl(master,F_SETFL,fcntl(master,F_GETFL)|O_NONBLOCK)>=0,
                  fcntl(master,F_SETFD,FD_CLOEXEC)>=0,fcntl(slave,F_SETFD,FD_CLOEXEC)>=0 else {throw POSIXError(.EIO)}
            return (FileHandle(fileDescriptor:master,closeOnDealloc:true),FileHandle(fileDescriptor:slave,closeOnDealloc:true))
        } catch {close(master);close(slave);throw error}
    }

    private func readable(_ descriptor:Int32,session token:UUID,cadence interval:Double) {
        lock.lock()
        guard session==token,!stopped else {lock.unlock();return}
        var bytes=[UInt8](repeating:0,count:64*1024)
        let count=bytes.withUnsafeMutableBytes {Darwin.read(descriptor,$0.baseAddress,$0.count)}
        let code=errno
        lock.unlock()
        if count>0 {received(Data(bytes.prefix(count)),session:token,cadence:interval)}
        else if count==0 || (code != EAGAIN && code != EINTR) {streamClosed(token)}
    }

    private func streamClosed(_ token:UUID) {
        lock.lock()
        guard session==token else {lock.unlock();return}
        let old=process,handle=output;process=nil;output=nil;latestRaw=nil;latest=nil;session=UUID();launchedAt=nil
        if !stopped {failure="Process network collection ended. Collection will retry.";retryAfter=Date().addingTimeInterval(30)}
        lock.unlock();Self.terminate(old,handle:handle)
    }

    private func received(_ data:Data,session token:UUID,cadence interval:Double) {
        lock.lock()
        guard session==token,!stopped else {lock.unlock();return}
        guard !data.isEmpty else {lock.unlock();return}
        do {
            let captures=try parser.consume(data,at:Date(),uptime:ProcessInfo.processInfo.systemUptime,cadence:interval)
            if let capture=captures.last {latestRaw=capture;failure=nil}
            lock.unlock()
        } catch {
            failure="Process network output could not be read safely. Collection will retry."
            retryAfter=Date().addingTimeInterval(30)
            let old=process,handle=output;process=nil;output=nil;session=UUID();latestRaw=nil;latest=nil;launchedAt=nil
            lock.unlock();Self.terminate(old,handle:handle)
        }
    }

    private func ended(_ token:UUID,status:Int32) {
        lock.lock()
        guard session==token else {lock.unlock();return}
        let handle=output;output=nil;process=nil;latestRaw=nil;latest=nil;session=UUID();launchedAt=nil
        if !stopped {failure=status==0 ? "Process network collection ended. Collection will retry." : "Process network collection is unavailable. Collection will retry.";retryAfter=Date().addingTimeInterval(30)}
        lock.unlock();handle?.readabilityHandler=nil;try? handle?.close()
    }

    private func endSession(markStopped:Bool) {
        lock.lock()
        stopped=markStopped
        let old=process,handle=output
        process=nil;output=nil;session=UUID();latestRaw=nil;latest=nil;cadence=nil;failure=nil;retryAfter=nil;launchedAt=nil
        identities.reset();parser=ProcessNetworkCSVParser()
        lock.unlock();Self.terminate(old,handle:handle)
    }

    private static func terminate(_ process:Process?,handle:FileHandle?) {
        handle?.readabilityHandler=nil;try? handle?.close()
        guard let process,process.isRunning else {return}
        process.terminationHandler=nil;process.terminate()
        // A single bounded termination escalation, not a sampling timer. Keep
        // the Process object alive until Foundation has reaped this child.
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+0.5) {
            if process.isRunning {kill(process.processIdentifier,SIGKILL)}
        }
    }
}
