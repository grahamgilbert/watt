import Foundation
import Darwin
import CTelemetry
import WattEnergyProtocol

// A fixed, bounded capture. There is no shell, configurable command, or caller-supplied path.
final class PowermetricsCapture {
    private final class Capture {
        let id=UUID()
        let owner:UUID
        let process=Process()
        let pipe=Pipe()
        let startedAt=Date()
        let reply:(Data?,String?)->Void
        var source:DispatchSourceRead?
        var output=Data()
        var failure:String?
        var exited=false
        var eof=false
        var exitStatus:Int32=0
        init(owner:UUID,reply:@escaping (Data?,String?)->Void) {self.owner=owner;self.reply=reply}
    }
    private let queue=DispatchQueue(label:"com.grahamgilbert.Watt.Energy.capture")
    private var current:Capture?
    private var owners=Set<UUID>()
    func connected(owner:UUID) {queue.async {self.owners.insert(owner)}}
    func capture(owner:UUID,reply:@escaping (Data?,String?)->Void) {
        queue.async { [self] in
            guard self.owners.contains(owner) else {reply(nil,"Energy client disconnected.");return}
            guard self.current == nil else {reply(nil,"An Apple energy capture is already running.");return}
            let capture=Capture(owner:owner,reply:reply);self.current=capture
            let process=capture.process
            process.executableURL=URL(fileURLWithPath:"/usr/bin/powermetrics")
            process.arguments=["--samplers","tasks","--show-process-energy","--show-responsible-pid","-f","plist","-n","1","-i","1000"]
            process.environment=["PATH":"/usr/bin:/bin:/usr/sbin:/sbin","LANG":"C","LC_ALL":"C"]
            process.currentDirectoryURL=URL(fileURLWithPath:"/")
            process.standardOutput=capture.pipe;process.standardError=FileHandle.nullDevice
            let fd=capture.pipe.fileHandleForReading.fileDescriptor
            _=fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK)
            let source=DispatchSource.makeReadSource(fileDescriptor:fd,queue:self.queue)
            capture.source=source
            source.setEventHandler { [weak self,weak capture] in
                guard let self,let capture else {return};self.drain(capture)
            }
            source.setCancelHandler { [weak capture] in try? capture?.pipe.fileHandleForReading.close() }
            source.resume()
            process.terminationHandler={ [weak self,weak capture] process in
                guard let self,let capture else {return}
                self.queue.async {
                    guard self.current === capture else {return}
                    capture.exited=true;capture.exitStatus=process.terminationStatus
                    self.drain(capture);self.finishIfReady(capture)
                }
            }
            do {try process.run();try? capture.pipe.fileHandleForWriting.close()}
            catch {
                capture.failure="Could not start Apple's energy sampler.";capture.exited=true;capture.eof=true
                source.cancel();self.finishIfReady(capture);return
            }
            self.queue.asyncAfter(deadline:.now()+8) {
                guard self.current === capture else {return}
                if capture.exited {
                    capture.failure="Apple energy output did not finish before its deadline."
                    capture.eof=true;capture.source?.cancel();self.finishIfReady(capture)
                } else {self.terminate(capture,reason:"Apple energy capture timed out.")}
            }
        }
    }
    func cancel(owner:UUID) {
        queue.async {
            self.owners.remove(owner)
            guard let capture=self.current,capture.owner==owner else {return}
            self.terminate(capture,reason:"Energy client disconnected.")
        }
    }
    private func terminate(_ capture:Capture,reason:String) {
        if capture.failure == nil {capture.failure=reason}
        if capture.process.isRunning {capture.process.terminate()}
        queue.asyncAfter(deadline:.now()+0.5) {
            guard self.current === capture,capture.process.isRunning else {return}
            kill(capture.process.processIdentifier,SIGKILL)
        }
    }
    private func drain(_ capture:Capture) {
        guard current === capture,!capture.eof else {return}
        var bytes=[UInt8](repeating:0,count:16384)
        let fd=capture.pipe.fileHandleForReading.fileDescriptor
        // Yield after at most 1 MiB so timeout/cancellation blocks cannot be starved.
        for _ in 0..<64 {
            let count=Darwin.read(fd,&bytes,bytes.count)
            if count>0 {
                if capture.output.count+count>EnergyServiceConfiguration.maximumOutputBytes {
                    terminate(capture,reason:"Apple energy output exceeded its size limit.")
                } else if capture.failure == nil {capture.output.append(contentsOf:bytes.prefix(count))}
            } else if count==0 {
                capture.eof=true;capture.source?.cancel();finishIfReady(capture);return
            } else {
                if errno==EAGAIN || errno==EWOULDBLOCK {return}
                if errno==EINTR {continue}
                capture.failure="Could not read Apple's energy sample.";capture.eof=true;capture.source?.cancel()
                terminate(capture,reason:capture.failure!);finishIfReady(capture);return
            }
        }
    }
    private func finishIfReady(_ capture:Capture) {
        guard current === capture,capture.exited,capture.eof else {return}
        current=nil;capture.source?.cancel();capture.source=nil
        guard capture.failure == nil,capture.exitStatus==0 else {
            capture.reply(nil,capture.failure ?? "Apple's energy sampler could not complete the capture.");return
        }
        do {
            let sample=try EnergyImpactParser.parse(capture.output,startedAt:capture.startedAt,endedAt:Date())
            let tasks=sample.tasks.map {task -> EnergyImpactTask in
                let start=watt_process_start_time(task.pid)
                let validStart=start>0 && Double(start)/1e6<=sample.startedAt.timeIntervalSince1970 ? start : nil
                return EnergyImpactTask(pid:task.pid,name:task.name,energyImpact:task.energyImpact,energyImpactPerSecond:task.energyImpactPerSecond,responsiblePID:task.responsiblePID,parentPID:task.parentPID,processStartMicroseconds:validStart)
            }
            let enriched=EnergyImpactSample(id:sample.id,startedAt:sample.startedAt,endedAt:sample.endedAt,tasks:tasks)
            try enriched.validate()
            let data=try JSONEncoder().encode(enriched)
            guard data.count<=EnergyServiceConfiguration.maximumOutputBytes else {throw EnergyImpactParseError.tooLarge}
            capture.reply(data,nil)
        } catch {capture.reply(nil,error.localizedDescription)}
    }
}
