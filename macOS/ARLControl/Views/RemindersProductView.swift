import SwiftUI

struct RemindersProductView: View {
    let controller:RemindersProductController
    let permissionState:String?
    let connect:()->Void
    let requestPermission:()->Void
    @State private var sourceID=""
    @State private var listID=""
    @State private var listTitle=""
    @State private var listTaskID=UUID().uuidString.lowercased()
    @State private var includeCompleted=false
    @State private var editing:RemindersProductItem?
    @State private var composeID=UUID().uuidString.lowercased()
    @State private var title=""
    @State private var notes=""
    @State private var priority=0
    @State private var dueMode="keep"
    @State private var dueDate=Date().addingTimeInterval(3600)
    @State private var dueTimed=false
    @State private var startMode="keep"
    @State private var startDate=Date().addingTimeInterval(3600)
    @State private var startTimed=true
    @State private var zone=TimeZone.current.identifier
    @State private var recurrenceMode="keep"
    @State private var frequency="daily"
    @State private var interval=1
    @State private var repeatEnd="count"
    @State private var repeatCount=3
    @State private var repeatUntil=Date().addingTimeInterval(86400*7)
    @State private var alertMode="keep"
    @State private var alertKind="relative"
    @State private var minutesBefore=5
    @State private var absoluteAlert=Date().addingTimeInterval(3300)
    private var frozen:Bool {controller.task?.task_id==composeID}
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            DetailCard(title:"提醒事项") {
                if permissionState != "authorized_full" {
                    Text("请先允许读取和写入提醒事项。").foregroundStyle(.secondary)
                    if permissionState=="not_determined" {Button("允许访问",action:requestPermission).disabled(controller.busy)}
                    else {Button("检查连接",action:connect).disabled(controller.busy)}
                    if permissionState=="denied" || permissionState=="restricted" {
                        Link("系统设置",destination:URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!)
                    }
                } else {
                    HStack {
                        Text(controller.target?.list?.title ?? "尚未选择清单")
                        Spacer()
                        Button("选择清单"){controller.discover()}.disabled(controller.busy)
                    }
                    if let catalog=controller.catalog {targetPicker(catalog)}
                    if controller.target?.list != nil {composer}
                }
                if let message=controller.message {Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)}
                if !controller.businessLogAvailable {Text("业务日志暂不可用；原操作的防重复记录仍保留。").font(.caption).foregroundStyle(.orange)}
                if let task=controller.task {
                    Text("操作："+task.task_id+" · "+task.state).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if controller.pendingTaskID != nil {
                    Button("查看原操作记录"){controller.refreshOperation()}.disabled(controller.busy)
                }
                DisclosureGroup("操作记录") {
                    Button("读取操作记录"){controller.refreshHistory()}.disabled(controller.busy)
                    ForEach(controller.history){row in
                        Button(row.title+" · "+row.state){controller.run(.init(.status,taskID:row.task_id))}.font(.caption).disabled(controller.busy)
                    }
                    if controller.historyNextOffset != nil {Button("更多"){controller.refreshHistory(more:true)}.disabled(controller.busy)}
                    ForEach(controller.operationIDs.reversed().filter{id in !controller.history.contains(where:{$0.id==id})},id:\.self){id in
                        Button(id){controller.run(.init(.status,taskID:id))}.font(.caption).disabled(controller.busy)
                    }
                }
            }
            if controller.target?.list != nil {itemsPanel}
        }
        .environment(\.timeZone,TimeZone(identifier:zone) ?? .current)
        .task {controller.restoreSelection()}
        .onChange(of:controller.target){_,target in
            if let target {sourceID=target.source.id;listID=target.list?.id ?? ""}
        }
    }
    @ViewBuilder private func targetPicker(_ catalog:RemindersProductCatalog)->some View {
        VStack(alignment:.leading,spacing:10) {
            Picker("来源",selection:$sourceID) {
                Text("请选择").tag("")
                ForEach(catalog.sources.filter{[0,1,2,3].contains($0.type)}){source in Text(source.title).tag(source.id)}
            }.onChange(of:sourceID){_,value in listID=controller.target?.source.id==value ? controller.target?.list?.id ?? "":""}
            Picker("清单",selection:$listID) {
                Text("请选择").tag("")
                ForEach(catalog.lists.filter{$0.source_id==sourceID && $0.writable}){list in Text(list.title).tag(list.id)}
            }
            HStack {
                Button("选用清单"){controller.select(sourceID:sourceID,listID:listID)}
                    .disabled(controller.busy || sourceID.isEmpty || listID.isEmpty)
                Text("之后的读写限定在所选清单；更换清单不重放旧任务。").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("新建清单") {
                if controller.target?.source.id != sourceID {
                    Button("选用此来源"){controller.select(sourceID:sourceID,listID:nil)}.disabled(controller.busy || sourceID.isEmpty)
                }
                HStack {
                    TextField("清单名称",text:$listTitle)
                    Button("创建清单") {
                        controller.submit("list.create",taskID:listTaskID,args:["source_id":sourceID,"title":listTitle])
                    }.disabled(controller.busy || controller.target?.source.id != sourceID || listTitle.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || controller.task?.task_id==listTaskID)
                    if controller.task?.task_id==listTaskID {
                        Button("另建清单"){listTitle="";listTaskID=UUID().uuidString.lowercased();controller.discover()}
                    }
                }
                Text("先选用来源。新清单建立后，再从目录中选用。").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical,6)
    }
    private var composer:some View {
        VStack(alignment:.leading,spacing:12) {
            Text(editing == nil ? "新建提醒":"编辑提醒").font(.headline)
            Group {
            TextField("标题",text:$title)
            TextField("备注",text:$notes,axis:.vertical).lineLimit(2...5)
            Picker("优先级",selection:$priority) {
                Text("无").tag(0);Text("高").tag(1);Text("中").tag(5);Text("低").tag(9)
            }
            dateFields("截止",mode:$dueMode,date:$dueDate,timed:$dueTimed)
            dateFields("开始",mode:$startMode,date:$startDate,timed:$startTimed)
            TextField("时区",text:$zone)
            if TimeZone(identifier:zone)==nil {Text("请输入有效的 IANA 时区。").foregroundStyle(.orange)}
            DisclosureGroup("重复与提醒时间") {
                VStack(alignment:.leading,spacing:10) {
                    modePicker("重复",selection:$recurrenceMode,editable:editing?.recurrence.editable ?? true)
                    if recurrenceMode=="set" {
                        Picker("频率",selection:$frequency) {
                            Text("每天").tag("daily");Text("每周").tag("weekly");Text("每月").tag("monthly");Text("每年").tag("yearly")
                        }
                        Stepper("每 "+String(interval)+" 个周期",value:$interval,in:1...999)
                        Picker("结束",selection:$repeatEnd) {Text("次数").tag("count");Text("截止日期").tag("until");Text("持续").tag("never")}
                        if repeatEnd=="count" {Stepper(String(repeatCount)+" 次",value:$repeatCount,in:1...9999)}
                        if repeatEnd=="until" {DatePicker("截止",selection:$repeatUntil)}
                        Text("重复需要指定开始日期。").font(.caption).foregroundStyle(.secondary)
                    }
                    modePicker("提醒时间",selection:$alertMode,editable:editing?.alerts.editable ?? true)
                    if alertMode=="set" {
                        Picker("方式",selection:$alertKind){Text("开始前").tag("relative");Text("指定时间").tag("absolute")}
                        if alertKind=="relative" {Stepper("提前 "+String(minutesBefore)+" 分钟",value:$minutesBefore,in:0...525600)}
                        else {DatePicker("提醒",selection:$absoluteAlert)}
                        Text("相对提醒需要带时间的开始日期。").font(.caption).foregroundStyle(.secondary)
                    }
                    if editing?.recurrence.editable==false || editing?.alerts.editable==false {
                        Text("已有复杂重复或提醒设置会保留；本页只修改支持的字段。").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            }.disabled(frozen || controller.busy)
            HStack {
                Button(editing == nil ? "创建提醒":"保存修改",action:save)
                    .buttonStyle(.borderedProminent).disabled(controller.busy || frozen || TimeZone(identifier:zone)==nil || title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                if frozen || editing != nil {Button("新建另一条"){load(nil)}.disabled(controller.busy)}
            }
            Text("本机保存结果与云同步分别记录。未知结果请查看原操作，勿用新编号重复提交相同内容。").font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func dateFields(_ label:String,mode:Binding<String>,date:Binding<Date>,timed:Binding<Bool>)->some View {
        HStack {
            modePicker(label,selection:mode)
            if mode.wrappedValue=="set" {
                Toggle("含时间",isOn:timed)
                if timed.wrappedValue {DatePicker(label,selection:date)}
                else {DatePicker(label,selection:date,displayedComponents:.date)}
            }
        }
    }
    private func modePicker(_ label:String,selection:Binding<String>,editable:Bool=true)->some View {
        Picker(label,selection:selection) {
            Text(editing == nil ? "不设置":"保持原值").tag("keep")
            if editable {Text("指定").tag("set");if editing != nil {Text("清除").tag("clear")}}
        }
    }
    private var itemsPanel:some View {
        DetailCard(title:"清单内容") {
            HStack {
                Toggle("包含已完成",isOn:$includeCompleted)
                Spacer()
                Button("读取清单"){controller.query(includeCompleted:includeCompleted)}.disabled(controller.busy)
            }
            ForEach(controller.items){item in
                HStack(alignment:.top) {
                    VStack(alignment:.leading,spacing:3) {
                        Text(item.title).strikethrough(item.completed)
                        if let due=item.due {Text("截止："+due.value).font(.caption).foregroundStyle(.secondary)}
                    }
                    Spacer()
                    Button("编辑"){load(item)}.disabled(controller.busy)
                    Button(item.completed ? "重新打开":"完成") {
                        controller.submit(item.completed ? "uncomplete":"complete",taskID:UUID().uuidString.lowercased(),
                            args:["list_id":item.list_id,"reminder_id":item.id,"expected_revision":item.revision])
                    }.disabled(controller.busy)
                }
            }
        }
    }
    private func dateValue(_ date:Date,timed:Bool)->[String:Any] {
        if timed {return ["kind":"date_time","value":ISO8601DateFormatter().string(from:date),"time_zone":zone]}
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.calendar=Calendar(identifier:.gregorian)
        formatter.timeZone=TimeZone(identifier:zone);formatter.dateFormat="yyyy-MM-dd"
        return ["kind":"date","value":formatter.string(from:date)]
    }
    private func save() {
        guard TimeZone(identifier:zone) != nil,let list=controller.target?.list else{return}
        var patch:[String:Any]=[:]
        func change(_ mode:String,_ value:Any)->[String:Any]? {mode=="keep" ? nil:mode=="clear" ? ["action":"clear"]:["action":"set","value":value]}
        if editing?.title != title,editing != nil {patch["title"]=["action":"set","value":title]}
        if (editing?.notes ?? "") != notes {patch["notes"]=notes.isEmpty ? ["action":"clear"]:["action":"set","value":notes]}
        if editing?.priority != priority {patch["priority"]=["action":"set","value":priority]}
        patch["due"]=change(dueMode,dateValue(dueDate,timed:dueTimed))
        patch["start"]=change(startMode,dateValue(startDate,timed:startTimed))
        var recurrence:[String:Any]=["frequency":frequency,"interval":interval]
        if repeatEnd=="count" {recurrence["count"]=repeatCount}
        if repeatEnd=="until" {recurrence["until"]=ISO8601DateFormatter().string(from:repeatUntil)}
        patch["recurrence"]=change(recurrenceMode,recurrence)
        let alert:[String:Any]=alertKind=="relative" ? ["kind":"relative","offset_seconds":-minutesBefore*60]:["kind":"absolute","at":ISO8601DateFormatter().string(from:absoluteAlert)]
        patch["alert"]=change(alertMode,alert)
        var args:[String:Any]=["list_id":list.id]
        if let editing {
            guard editing.list_id==list.id else{return}
            args["reminder_id"]=editing.id;args["expected_revision"]=editing.revision;args["patch"]=patch
        } else {args["title"]=title;if !patch.isEmpty{args["patch"]=patch}}
        controller.submit(editing == nil ? "create":"update",taskID:composeID,args:args)
    }
    private func load(_ item:RemindersProductItem?) {
        editing=item;composeID=UUID().uuidString.lowercased();title=item?.title ?? "";notes=item?.notes ?? "";priority=item?.priority ?? 0
        dueMode="keep";startMode="keep";recurrenceMode="keep";alertMode="keep"
        zone=item?.due?.time_zone ?? item?.start?.time_zone ?? TimeZone.current.identifier
    }
}
