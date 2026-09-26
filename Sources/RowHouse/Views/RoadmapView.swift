import RowHouseCore
import SwiftUI

/// Timeline view: one bar per record from its start date to its end date, in swimlanes when grouped.
struct RoadmapView: View {
    let session: BaseSession
    let view: ViewModel
    var state: WindowState
    let commandTarget: GridCommandTarget

    var body: some View {
        ScheduleChart(session: session, view: view, state: state, commandTarget: commandTarget, style: .timeline)
    }
}

/// Gantt view: the timeline plus dependency arrows between records.
struct GanttView: View {
    let session: BaseSession
    let view: ViewModel
    var state: WindowState
    let commandTarget: GridCommandTarget

    var body: some View {
        ScheduleChart(session: session, view: view, state: state, commandTarget: commandTarget, style: .gantt)
    }
}
