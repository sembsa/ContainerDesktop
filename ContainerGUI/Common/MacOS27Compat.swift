import SwiftUI

/// macOS 27 presentation and interaction APIs with macOS 26 fallbacks.
///
/// The deployment target is still macOS 26, so every new API lives behind
/// `#available`. On 27 these helpers use the item-driven `alert` /
/// `confirmationDialog` overloads, swipe actions in scrollable containers and
/// drag-to-reorder; on 26 they fall back to the `isPresented:` + `presenting:`
/// shape or to doing nothing.
extension View {
    /// `alert(_:item:actions:message:)` from macOS 27; one optional binding
    /// drives presentation and supplies the value. The title is a key because
    /// the new overload has no `Text` variant when a message is present.
    @ViewBuilder
    func itemAlert<Item: Sendable, Actions: View, Message: View>(
        _ titleKey: LocalizedStringKey,
        item: Binding<Item?>,
        @ViewBuilder actions: @escaping (Item) -> Actions,
        @ViewBuilder message: @escaping (Item) -> Message
    ) -> some View {
        if #available(macOS 27.0, *) {
            alert(titleKey, item: item, actions: actions, message: message)
        } else {
            alert(
                titleKey,
                isPresented: item.isPresent(),
                presenting: item.wrappedValue,
                actions: actions,
                message: message
            )
        }
    }

    /// `confirmationDialog(_:item:actions:message:)` from macOS 27.
    @ViewBuilder
    func itemConfirmationDialog<Item: Sendable, Actions: View, Message: View>(
        _ title: Text,
        item: Binding<Item?>,
        @ViewBuilder actions: @escaping (Item) -> Actions,
        @ViewBuilder message: @escaping (Item) -> Message
    ) -> some View {
        if #available(macOS 27.0, *) {
            confirmationDialog(title, item: item, actions: actions, message: message)
        } else {
            confirmationDialog(
                title,
                isPresented: item.isPresent(),
                presenting: item.wrappedValue,
                actions: actions,
                message: message
            )
        }
    }

    /// `confirmationDialog(_:item:actions:)` from macOS 27 — no message.
    @ViewBuilder
    func itemConfirmationDialog<Item: Sendable, Actions: View>(
        _ title: Text,
        item: Binding<Item?>,
        @ViewBuilder actions: @escaping (Item) -> Actions
    ) -> some View {
        if #available(macOS 27.0, *) {
            confirmationDialog(title, item: item, actions: actions)
        } else {
            confirmationDialog(
                title,
                isPresented: item.isPresent(),
                presenting: item.wrappedValue,
                actions: actions
            )
        }
    }

    /// Enables `swipeActions` on rows of a `ScrollView`/`LazyVStack` (macOS 27);
    /// on macOS 26 the row modifiers are simply inert.
    @ViewBuilder
    func swipeActionsContainerCompat() -> some View {
        if #available(macOS 27.0, *) {
            swipeActionsContainer()
        } else {
            self
        }
    }

    /// Drag-to-reorder for a single `ForEach` marked `.reorderable()` inside
    /// this container (macOS 27); no-op earlier.
    @ViewBuilder
    func reorderContainerCompat<Item: Identifiable & Sendable>(
        items: Binding<[Item]>
    ) -> some View where Item.ID: Sendable {
        if #available(macOS 27.0, *) {
            reorderContainer(for: Item.self) { difference in
                var reordered = items.wrappedValue
                difference.apply(to: &reordered)
                items.wrappedValue = reordered
            }
        } else {
            self
        }
    }
}

private extension Binding {
    /// Presents while the optional holds a value; dismissal clears it.
    func isPresent<Wrapped: Sendable>() -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(
            get: { self.wrappedValue != nil },
            set: { if !$0 { self.wrappedValue = nil } }
        )
    }
}

@available(macOS 27.0, *)
extension ReorderDifference where CollectionID == ReorderableSingleCollectionIdentifier {
    /// Applies the move to a single collection: drops the moved items in one
    /// in-place pass, then reinserts them at the destination.
    func apply<C>(to collection: inout C)
        where C: RangeReplaceableCollection,
              C.Element: Identifiable,
              C.Element.ID == ItemID
    {
        let moving = Set(sources)
        guard !moving.isEmpty else { return }

        var moved: [C.Element] = []
        moved.reserveCapacity(moving.count)
        collection.removeAll { element in
            guard moving.contains(element.id) else { return false }
            moved.append(element)
            return true
        }

        switch destination.position {
        case .before(let id):
            let index = collection.firstIndex { $0.id == id } ?? collection.endIndex
            collection.insert(contentsOf: moved, at: index)
        case .end:
            collection.append(contentsOf: moved)
        }
    }
}
