import SwiftUI
import Charts

// The overview uses the same recorded samples as Process Explorer.
struct PopupDashboard:View {
    let frame:Frame
    let frames:[Frame]
    private var physical:Double {Double(ProcessInfo.processInfo.physicalMemory)}
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(alignment:.top,spacing:20) {
                VStack(alignment:.leading,spacing:6) {
                    heading("CPU",color:.mint)
                    reading(String(format:"%.0f",frame.cpu),unit:"%")
                    PopupSpark(frames:frames,color:.mint,ceiling:100,value:{$0.cpu}).frame(height:56)
                    Text("Machine capacity").font(.system(size:10)).foregroundStyle(.secondary)
                }
                VStack(alignment:.leading,spacing:6) {
                    heading("MEMORY",color:.purple)
                    reading(String(format:"%.0f",Double(frame.memory)/physical*100),unit:"%")
                    PopupSpark(frames:frames,color:.purple,ceiling:100,value:{Double($0.memory)/physical*100}).frame(height:56)
                    Text("\(bytes(frame.memory)) used · cache excluded").font(.system(size:10)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing:12) {
                Text("Compressed \(bytes(frame.compressed))")
                Spacer(minLength:0)
                Text("Swap \(bytes(frame.swap))")
            }.font(.system(size:10)).foregroundStyle(.secondary)
            Divider()
            HStack {heading("NETWORK",color:.cyan);Spacer();Text(historyDuration).font(.system(size:10)).foregroundStyle(.tertiary)}
            HStack(spacing:20) {
                networkLane("↓ Download",rate:frame.download,color:.cyan,value:{$0.download})
                networkLane("↑ Upload",rate:frame.upload,color:.orange,value:{$0.upload})
            }
            Divider()
            HStack(spacing:16) {
                VStack(alignment:.leading,spacing:5) {
                    heading("BATTERY FLOW",color:.yellow)
                    Text(frame.power?.formatted ?? "Unavailable").font(.system(size:22,weight:.medium,design:.rounded)).monospacedDigit()
                    Text(frame.power.map { $0.externalPower ? ($0.watts > 0.05 ? "Charging · estimate" : "External power · estimate") : "Discharging · estimate" } ?? "Sensor unavailable").font(.system(size:10)).foregroundStyle(.secondary)
                }.fixedSize(horizontal:true,vertical:false)
                PopupSpark(frames:frames,color:.yellow,ceiling:nil,value:{ f in
                    guard let p=f.power,p.hasUsableCurrent else {return nil};return abs(p.watts)
                }).frame(height:48)
            }.help("Estimated battery flow magnitude. This is not total system power on AC.")
            Divider()
            VStack(alignment:.leading,spacing:9) {
                HStack {heading("BUSIEST PROCESSES",color:.mint);Spacer();Text("CPU · 100% = one core").font(.system(size:10)).foregroundStyle(.tertiary)}
                ForEach(frame.processes.sorted {($0.cpu ?? -1)>($1.cpu ?? -1)}.prefix(3)) {process in
                    HStack(spacing:10) {
                        Text(process.name).font(.system(size:11)).lineLimit(1).frame(width:118,alignment:.leading)
                        GeometryReader {geometry in
                            Capsule().fill(.primary.opacity(0.06))
                            Capsule().fill(Color.mint.opacity(0.65)).frame(width:geometry.size.width*min(1,max(0,(process.cpu ?? 0)/100)))
                        }.frame(height:4)
                        Text(process.cpu.map {String(format:"%.1f%%",$0)} ?? "—").font(.system(size:10,weight:.medium)).monospacedDigit().frame(width:43,alignment:.trailing)
                    }
                }
            }
        }
    }
    private var historyDuration:String {
        guard let first=frames.first,let last=frames.last else {return ""}
        let seconds=max(0,Int(last.time.timeIntervalSince(first.time)))
        return seconds>=60 ? "Last \(seconds/60)m \(seconds%60)s" : "Last \(seconds)s"
    }
    private func heading(_ title:String,color:Color)->some View {
        HStack(spacing:5) {Circle().fill(color).frame(width:4,height:4);Text(title).font(.system(size:9,weight:.semibold)).tracking(1)}.foregroundStyle(.secondary)
    }
    private func reading(_ text:String,unit:String)->some View {
        HStack(alignment:.firstTextBaseline,spacing:2) {Text(text).font(.system(size:34,weight:.medium,design:.rounded)).monospacedDigit();Text(unit).font(.system(size:15)).foregroundStyle(.secondary)}
    }
    private func networkLane(_ title:String,rate:Double,color:Color,value:@escaping (Frame)->Double?)->some View {
        VStack(alignment:.leading,spacing:6) {
            Text(title).font(.system(size:10,weight:.medium)).foregroundStyle(color)
            Text("\(compactNetworkRate(rate))/s").font(.system(size:21,weight:.medium,design:.rounded)).monospacedDigit()
            PopupSpark(frames:frames,color:color,ceiling:max(1,frames.map {max($0.download,$0.upload)}.max() ?? 1),value:value).frame(height:46)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}

private struct PopupSpark:View {
    let frames:[Frame]
    let color:Color
    let ceiling:Double?
    let value:(Frame)->Double?
    private struct Point:Identifiable {let id:Date;let value:Double;let segment:String}
    private var points:[Point] {
        var run=0
        return frames.compactMap {frame in
            guard let value=value(frame),value.isFinite else {run+=1;return nil}
            return Point(id:frame.time,value:value,segment:(frame.segment ?? "legacy")+"-\(run)"+((frame.power?.externalPower == true) ? "-ac" : "-battery"))
        }
    }
    private var range:ClosedRange<Double> {
        let values=points.map(\.value)
        let low=min(0,values.min() ?? 0)
        let high=ceiling ?? max(1,values.max() ?? 1)
        return low...max(low+1,high)
    }
    var body:some View {
        Chart(points) {point in
            AreaMark(x:.value("Time",point.id),yStart:.value("Baseline",0),yEnd:.value("Value",point.value),series:.value("Segment",point.segment))
                .foregroundStyle(LinearGradient(colors:[color.opacity(0.27),color.opacity(0.025)],startPoint:.top,endPoint:.bottom))
            LineMark(x:.value("Time",point.id),y:.value("Value",point.value),series:.value("Segment",point.segment))
                .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth:1.8,lineCap:.round,lineJoin:.round))
        }.chartYScale(domain:range).chartXAxis(.hidden).chartYAxis(.hidden)
            .overlay(alignment:.bottom) {Rectangle().fill(.primary.opacity(0.08)).frame(height:0.5)}
            .accessibilityLabel("Recent metric history")
    }
}
