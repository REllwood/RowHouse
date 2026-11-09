/// An automation being edited: the saved version the edits started from, and the edits. Saving applies
/// only the properties that were edited, so anything saved elsewhere meanwhile (on another Mac, by an AI
/// assistant, or with the on/off switch in the list) is kept.
public struct AutomationDraft: Equatable, Sendable {
    /// The saved version these edits are compared with.
    public private(set) var base: AutomationModel
    public var model: AutomationModel

    public init(_ saved: AutomationModel) {
        base = saved
        model = saved
    }

    public var hasEdits: Bool { model != base }

    /// The saved version changed elsewhere: take its changes, keeping these edits on top.
    public mutating func savedVersionChanged(to saved: AutomationModel) {
        model = saved.applyingEdits(from: model, since: base)
        base = saved
    }

    /// `current` with this draft's edits applied: what to save.
    public func applied(to current: AutomationModel) -> AutomationModel {
        current.applyingEdits(from: model, since: base)
    }

    /// The edits were saved and this is the result.
    public mutating func saved(as saved: AutomationModel) {
        base = saved
        model = saved
    }
}

extension AutomationModel {
    /// This automation with the properties `edited` changed relative to `base`.
    func applyingEdits(from edited: AutomationModel, since base: AutomationModel) -> AutomationModel {
        var result = self
        if edited.name != base.name { result.name = edited.name }
        if edited.description != base.description { result.description = edited.description }
        if edited.enabled != base.enabled { result.enabled = edited.enabled }
        if edited.trigger != base.trigger { result.trigger = edited.trigger }
        if edited.actions != base.actions { result.actions = edited.actions }
        if edited.order != base.order { result.order = edited.order }
        return result
    }
}
