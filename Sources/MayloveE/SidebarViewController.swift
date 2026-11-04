import AppKit

/// The left tool window area: Project (file tree) or Commit, switched by a segmented control.
@MainActor
final class SidebarViewController: NSViewController {
    enum Pane: Int {
        case project
        case commit
    }

    private let panes: [NSViewController]
    private let switcher = NSSegmentedControl()
    private let contentView = NSView()
    /// Buttons right of the switcher, e.g. the file tree's actions.
    private let actionsView: NSView?
    private(set) var selectedPane = Pane.project

    init(project: NSViewController, commit: NSViewController, actions: NSView? = nil) {
        panes = [project, commit]
        actionsView = actions
        super.init(nibName: nil, bundle: nil)
        panes.forEach(addChild)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        switcher.segmentCount = 2
        switcher.setLabel("Project", forSegment: Pane.project.rawValue)
        switcher.setLabel("Commit", forSegment: Pane.commit.rawValue)
        switcher.setToolTip("Project (⌘1)", forSegment: Pane.project.rawValue)
        switcher.setToolTip("Commit (⌘0)", forSegment: Pane.commit.rawValue)
        switcher.segmentDistribution = .fillEqually
        switcher.controlSize = .regular
        switcher.target = self
        switcher.action = #selector(switcherChanged)

        let header = NSStackView(views: [switcher] + (actionsView.map { [$0] } ?? []))
        header.orientation = .horizontal
        header.spacing = 8
        actionsView?.setContentHuggingPriority(.required, for: .horizontal)
        actionsView?.setContentCompressionResistancePriority(.required, for: .horizontal)

        let container = NSView()
        for subview in [header, contentView] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            // Below the toolbar: the sidebar extends under the titlebar.
            header.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            contentView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            contentView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        select(.project)
    }

    func select(_ pane: Pane) {
        loadViewIfNeeded()
        selectedPane = pane
        switcher.selectedSegment = pane.rawValue
        contentView.subviews.forEach { $0.removeFromSuperview() }
        let paneView = panes[pane.rawValue].view
        paneView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(paneView)
        NSLayoutConstraint.activate([
            paneView.topAnchor.constraint(equalTo: contentView.topAnchor),
            paneView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            paneView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            paneView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    /// Shows the number of changed files on the Commit segment.
    func setCommitCount(_ count: Int) {
        loadViewIfNeeded()
        switcher.setLabel(count > 0 ? "Commit (\(count))" : "Commit", forSegment: Pane.commit.rawValue)
    }

    @objc private func switcherChanged() {
        select(Pane(rawValue: switcher.selectedSegment) ?? .project)
    }
}
