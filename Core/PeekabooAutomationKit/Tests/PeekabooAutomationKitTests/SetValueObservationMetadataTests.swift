import Testing
@_spi(Testing) @testable import PeekabooAutomationKit

/// `see` marks controls that `set_value` can set as "[value settable]" (and so actionable).
struct SetValueObservationMetadataTests {
    @Test
    func `date picker value settability is read like other value controls`() {
        #expect(ElementClassifier.supportsValueMetadata(for: "AXDateTimeArea"))
    }

    @Test
    func `stepper with increment and decrement counts as settable though its AXValue is read-only`() {
        #expect(DetachedAXObservationWorker.settableBySetValue(
            role: "AXIncrementor",
            axValueSettable: false,
            actions: ["AXIncrement", "AXDecrement"],
            parentRole: "AXWindow") == true)
    }

    @Test
    func `stepper inside a date picker is left read-only; set the date picker instead`() {
        #expect(DetachedAXObservationWorker.settableBySetValue(
            role: "AXIncrementor",
            axValueSettable: false,
            actions: ["AXIncrement", "AXDecrement"],
            parentRole: "AXDateTimeArea") == false)
    }

    @Test
    func `other controls keep their AX settability`() {
        #expect(DetachedAXObservationWorker.settableBySetValue(
            role: "AXSlider", axValueSettable: true, actions: ["AXIncrement"], parentRole: nil) == true)
        #expect(DetachedAXObservationWorker.settableBySetValue(
            role: "AXCheckBox", axValueSettable: false, actions: ["AXPress"], parentRole: nil) == false)
        #expect(DetachedAXObservationWorker.settableBySetValue(
            role: "AXIncrementor", axValueSettable: nil, actions: [], parentRole: nil) == nil)
    }
}
