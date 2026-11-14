# coding_agent_framework

Run and supervise Claude Code agents across Claude accounts and machines.

- **Parent sessions** are a project's main chats. Each moves to another account with one press,
  keeping its name and its Remote Control.
- **Delegates** are full Claude Code sessions a parent starts on the account with the most
  allowance left. Each runs in its own git worktree and tmux session, held by dtach so it outlives
  its terminal, and reports back to its parent.
- **Stacked pull requests** (`gh stack`) carry the work of a parent and its delegates.
- **State for LiveView frontends** follows what really runs, without lag or drift.
- **A TLA+ model**, checked with TLC, describes how tmux, dtach, Claude Code, worktrees and stacks
  fit together. It is written before the code it models.

Status: design. Nothing is built yet; the plan is in [docs/design.md](docs/design.md).

## License

Apache-2.0; see [LICENSE](LICENSE).
