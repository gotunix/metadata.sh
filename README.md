# metadata.sh

A git-first metadata engine for tracking tasks, stories, milestones, and implementation plans directly in your repository. It uses simple JSON and Markdown files to keep your project metadata close to your code, versioned, and easily searchable.

## Features

- **Task Management**: Create, edit, and track task status.
- **Milestones & Stories**: Group tasks into stories and milestones for higher-level tracking.
- **Implementation Plans**: Detailed Markdown-based plans linked to tasks.
- **Changelog Generation**: Automatically generate `CHANGELOG.md` from completed tasks and milestones.
- **Dashboard**: Visual overview of your project status.

## Installation

1. Copy `metadata.sh` to your project root or a directory in your `PATH`.
2. Ensure it is executable: `chmod +x metadata.sh`.

## Usage

```bash
# Create a task
./metadata.sh task-create "My New Task" "my-task" "HIGH" "FEAT"

# View the dashboard
./metadata.sh dashboard

# Generate changelog
./metadata.sh changelog .
```

## Recommended Workflow: Orphan Branch & Worktree

To keep your project history clean and avoid cluttering your main branch with metadata files, we recommend using an **orphan branch**. This allows you to store all your tasks and plans in the same repository but on a completely independent timeline.

### 1. Create the Orphan Branch

This creates a branch with no parent history and initializes the metadata structure.

```bash
git checkout --orphan metadata
git rm -rf .
mkdir tasks milestones stories plans
touch tasks/.gitkeep milestones/.gitkeep stories/.gitkeep plans/.gitkeep
git add .
git commit -m "Initialize metadata structure"
git checkout main
```

### 2. Add as a Worktree

To make management easy, you can add the `metadata` branch as a **git worktree** inside your main codebase. This allows you to have the metadata directory available without switching branches.

```bash
git worktree add metadata metadata
```

### 3. Ignore the Worktree

You must add the `metadata/` directory to your `.gitignore` file.

**Why?**
A git worktree is a separate checkout. If you don't ignore it, your main branch will see the `metadata/` folder as a collection of "untracked files". Ignoring it keeps your `git status` clean and ensures that metadata commits are kept strictly on the `metadata` branch.

**How?**
```bash
echo "metadata/" >> .gitignore
```

### 4. Running the Script

Because the script manages data relative to its own location, you simply run it from within the `metadata/` directory. This ensures all JSON and Markdown files are created and updated within that worktree.

```bash
cd metadata/
../metadata.sh dashboard
```

## License

BSD 3-Clause License. See `LICENSE` for details.
