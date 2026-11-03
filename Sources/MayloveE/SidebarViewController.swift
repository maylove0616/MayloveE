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
    private(set) var selectedPane = Pane.project

    init(project: NSViewController, commit: NSViewController) {
        panes = [project, commit]
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
        switcher.controlSize = .small
        switcher.target = self
        switcher.action = #selector(switcherChanged)

        let container = NSView()
        for subview in [switcher, contentView] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            // Below the toolbar: the sidebar extends under the titlebar.
            switcher.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 6),
            switcher.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            switcher.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            contentView.topAnchor.constraint(equalTo: switcher.bottomAnchor, constant: 6),
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
