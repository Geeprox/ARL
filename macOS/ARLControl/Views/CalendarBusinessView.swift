import SwiftUI

/// A business page: normal calendar names, date range, event list and editor.
/// UI and Mio share the same validation and direct execution without another dialog.
struct CalendarBusinessView: View {
    @Bindable var controller: CalendarBusinessController
    @State private var rangeStart = Calendar.current.startOfDay(for: Date())
    @State private var rangeEnd = Calendar.current.date(byAdding: .day, value: 7, to: Calendar.current.startOfDay(for: Date()))!
    @State private var title = ""
    @State private var start = Date().addingTimeInterval(3600)
    @State private var end = Date().addingTimeInterval(7200)
    @State private var allDay = false
    @State private var timeZone = TimeZone.current.identifier
    @State private var alarms: [Int] = []
    @State private var repeatFrequency: CalendarBusinessFrequency?
    @State private var interval = 1
    @State private var repeatCount = 10
    @State private var repeatUntil: String?
    @State private var taskID = UUID().uuidString.lowercased()
    @State private var deleteTaskID = UUID().uuidString.lowercased()

    private var draft: CalendarBusinessDraft {
        let recurrence = repeatFrequency.map { CalendarBusinessRecurrence(frequency:$0, interval:interval,
            count: repeatUntil == nil && repeatCount > 0 ? repeatCount:nil, until:repeatUntil) }
        return .init(calendar_id:controller.permission.state == .writeOnly ? nil:controller.selectedCalendarID,
                     title:title, start:CalendarBusinessContract.string(start), end:CalendarBusinessContract.string(end),
                     time_zone:timeZone, all_day:allDay, alarm_seconds:alarms, recurrence:recurrence)
    }
    private var editable: Bool { controller.selectedEvent?.editable ?? true }
    private var writable: Bool {
        controller.permission.state == .writeOnly || controller.calendars.contains { $0.id == controller.selectedCalendarID && $0.writable }
    }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading, spacing:20) {
                HStack {
                    Text("日历").font(.title2.bold())
                    Spacer()
                    Text(controller.permission.state.title).foregroundStyle(.secondary)
                }
                permissionSection
                if controller.permission.state == .fullAccess {
                    rangeSection
                    eventsSection
                }
                if controller.permission.state == .writeOnly || controller.permission.state == .fullAccess {
                    editorSection
                }
                if controller.unresolved, let id=controller.currentTaskID {
                    Text("结果待核，原任务不会重放。").foregroundStyle(.secondary)
                    Button("查看结果") { Task { await controller.status(taskID:id) } }.disabled(!controller.canAct)
                }
                if let message=controller.message { Text(message).font(.callout).foregroundStyle(.secondary) }
                if let at=controller.observedAt {
                    Text("最近更新：" + at.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary)
                }
                if controller.busy { ProgressView().controlSize(.small) }
            }.padding(24)
        }
        .task { await controller.prepareForDisplay();await controller.query(start:rangeStart,end:rangeEnd) }
        .onChange(of:controller.selectedEvent) { _, value in load(value) }
        .onChange(of:controller.selectedCalendarID) { _, _ in Task { await controller.query(start:rangeStart,end:rangeEnd) } }
        .onChange(of:allDay) { _, value in if value { normalizeAllDay() } }
        .onChange(of:timeZone) { _, _ in if allDay { normalizeAllDay() } }
    }
    @ViewBuilder private var permissionSection: some View {
        let permission=controller.permission
        switch permission.state {
        case .writeOnly:
            Text("仅可向默认日历新建。").foregroundStyle(.secondary)
            Button("允许读写") { Task { await permission.requestFullAccess(); await controller.loadCalendars(); await controller.query(start:rangeStart,end:rangeEnd) } }.disabled(!controller.canAct)
        case .notDetermined:
            Text("查看及编辑需要读写权限。").foregroundStyle(.secondary)
            Button("允许读写") { Task { await permission.requestFullAccess(); await controller.loadCalendars(); await controller.query(start:rangeStart,end:rangeEnd) } }.disabled(!controller.canAct)
        case .denied, .restricted:
            Text("请在系统设置中核对日历。").foregroundStyle(.secondary)
            Link("系统设置",destination:URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
        case .unknown:
            Text("权限暂未更新，请稍后再试。").foregroundStyle(.secondary)
        case .disabled:
            Text("当前环境未开放日历。").foregroundStyle(.secondary)
        case .fullAccess: EmptyView()
        }
        if permission.lastProbeFailed { Text("更新失败，保留最近状态。").font(.caption).foregroundStyle(.secondary) }
        if let message=permission.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        if !controller.businessLogAvailable {Text("业务日志暂不可用；任务防重复记录仍保留。").font(.caption).foregroundStyle(.orange)}
        ForEach(controller.archivedTaskIDs,id:\.self){id in
            HStack {Text("待核操作："+id).font(.caption).textSelection(.enabled);Button("查看原记录"){Task{await controller.status(taskID:id)}}.disabled(controller.busy)}
        }
        if controller.unresolved {Button("另建日程"){controller.startNewIntent();load(nil)}.disabled(!controller.canAct)}
    }
    private var rangeSection: some View {
        VStack(alignment:.leading,spacing:10) {
            Picker("日历",selection:Binding(get:{controller.selectedCalendarID ?? ""},set:{ controller.selectCalendar($0.isEmpty ? nil:$0) })) {
                Text("选择日历").tag("")
                ForEach(controller.calendars) { calendar in
                    Text(calendar.source + " / " + calendar.title + (calendar.writable ? "":"（只读）")).tag(calendar.id)
                }
            }.disabled(controller.busy || controller.unresolved)
            HStack {
                DatePicker("从",selection:$rangeStart,displayedComponents:.date)
                DatePicker("至",selection:$rangeEnd,displayedComponents:.date)
                Button("查找日程") { Task { await controller.query(start:rangeStart,end:rangeEnd) } }
                    .disabled(!controller.canRead || controller.selectedCalendarID == nil || rangeEnd <= rangeStart)
            }
            Text("结束日期当天不计入。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var eventsSection: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Text("日程").font(.headline)
                Spacer()
                Button(controller.unresolved ? "另建日程":"新建日程") { controller.startNewIntent(); load(nil) }.disabled(!controller.canAct)
            }
            if controller.displayedQuery == nil { Text("选择日期后查找日程。").foregroundStyle(.secondary) }
            else if controller.displayedQuery?.calendar_ids != [controller.selectedCalendarID ?? ""] { Text("正在查看所选日历。").foregroundStyle(.secondary) }
            else if controller.events.isEmpty { Text("此日期范围暂无日程。").foregroundStyle(.secondary) }
            ForEach(controller.displayedQuery?.calendar_ids == [controller.selectedCalendarID ?? ""] ? controller.events:[]) { event in
                Button {
                    controller.selectEvent(event)
                } label: {
                    HStack(alignment:.top) {
                        VStack(alignment:.leading,spacing:4) {
                            Text(event.draft.title).foregroundStyle(.primary)
                            Text(display(event.draft.start) + " – " + display(event.draft.end)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if event.repeating { Text("重复").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical,5).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(controller.busy || controller.unresolved)
                Divider()
            }
            if controller.truncated { Text("结果较多，请缩短日期范围。").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var editorSection: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text(controller.selectedEvent == nil ? "新建日程":"编辑日程").font(.headline)
                Spacer()
                if controller.offersDefaultCreate {
                    Button("默认新建") { controller.startNewIntent();load(nil) }.disabled(!controller.canAct)
                }
            }
            if !editable { Text("邀请或复杂日程暂不支持编辑。").font(.caption).foregroundStyle(.secondary) }
            TextField("日程名称",text:$title)
            Toggle("全天",isOn:$allDay)
            DatePicker("开始",selection:$start,displayedComponents:allDay ? [.date]:[.date,.hourAndMinute])
            DatePicker("结束",selection:$end,displayedComponents:allDay ? [.date]:[.date,.hourAndMinute])
            TextField("时区",text:$timeZone)
            Picker("提醒",selection:Binding(get:{alarms.first ?? -1},set:{alarms=$0 < 0 ? []:[$0]})) {
                Text("不提醒").tag(-1);Text("准时").tag(0);Text("提前五分").tag(300);Text("提前十分").tag(600);Text("提前半时").tag(1800);Text("提前一天").tag(86400)
                if let current=alarms.first, ![0,300,600,1800,86400].contains(current) { Text("原提醒").tag(current) }
            }
            Picker("重复",selection:$repeatFrequency) {
                Text("不重复").tag(Optional<CalendarBusinessFrequency>.none)
                ForEach(CalendarBusinessFrequency.allCases,id:\.self) { f in Text(f.title).tag(Optional(f)) }
            }.disabled(controller.selectedEvent?.repeating == true)
            if repeatFrequency != nil {
                Stepper("间隔：\(interval)",value:$interval,in:1...99).disabled(controller.selectedEvent?.repeating == true)
                if repeatUntil != nil { Text("结束：" + display(repeatUntil!)).font(.caption) }
                else { Stepper(repeatCount == 0 ? "持续重复":"重复：\(repeatCount) 次",value:$repeatCount,in:0...999).disabled(controller.selectedEvent?.repeating == true) }
            }
            if controller.selectedEvent?.repeating == true { Text("修改及删除仅影响本次日程。").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button(controller.selectedEvent == nil ? "新建日程":"保存修改") { Task { await controller.save(draft,taskID:taskID) } }
                    .disabled(!controller.canAct || !editable || !writable || controller.unresolved || (try? draft.validate()) == nil)
                if controller.selectedEvent != nil {
                    Button("删除本次",role:.destructive) { Task { await controller.delete(taskID:deleteTaskID) } }
                        .disabled(!controller.canRead || !editable || controller.unresolved)
                }
            }
        }.disabled(controller.busy || controller.unresolved)
    }
    private func load(_ event:CalendarBusinessEvent?) {
        guard !controller.unresolved else { return }
        taskID=UUID().uuidString.lowercased();deleteTaskID=UUID().uuidString.lowercased()
        title=event?.draft.title ?? "";start=(try? CalendarBusinessContract.date(event?.draft.start ?? "")) ?? Date().addingTimeInterval(3600)
        end=(try? CalendarBusinessContract.date(event?.draft.end ?? "")) ?? start.addingTimeInterval(3600)
        allDay=event?.draft.all_day ?? false;timeZone=event?.draft.time_zone ?? TimeZone.current.identifier
        alarms=event?.draft.alarm_seconds ?? [];repeatFrequency=event?.draft.recurrence?.frequency
        interval=event?.draft.recurrence?.interval ?? 1;repeatCount=event?.draft.recurrence?.count ?? 0;repeatUntil=event?.draft.recurrence?.until
    }
    private func normalizeAllDay() {
        var c=Calendar(identifier:.gregorian);c.timeZone=TimeZone(identifier:timeZone) ?? .current
        start=c.startOfDay(for:start);end=c.startOfDay(for:end)
        if end <= start { end=c.date(byAdding:.day,value:1,to:start)! }
    }
    private func display(_ value:String)->String {
        (try? CalendarBusinessContract.date(value))?.formatted(date:.abbreviated,time:.shortened) ?? value
    }
}
