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

To keep your metadata history separate from your source code history while keeping them in the same repository, we recommend using an **orphan branch**.

### 1. Create the Orphan Branch

This creates a branch with no history and initializes the metadata structure.

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

This allows you to have the `metadata` branch checked out in a subdirectory of your `main` branch.

```bash
git worktree add metadata metadata
```

### 3. Ignore the Worktree

Add the metadata directory to your `.gitignore` so it isn't tracked as part of your main branch.

```bash
echo "metadata/" >> .gitignore
```

### 4. Configure the Script

When running `metadata.sh` from your root, point it to the worktree using the `METADATA_DIR` environment variable:

```bash
export METADATA_DIR=./metadata
./metadata.sh dashboard
```

Alternatively, you can place a copy of `metadata.sh` inside the `metadata/` directory and run it from there.

## License

BSD 3-Clause License. See `LICENSE` for details.
