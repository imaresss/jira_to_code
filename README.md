# 🚀 Jira to Code Automator (`jira_to_code`)

`jira_to_code` is an interactive Bash script designed to streamline your development workflow. It bridges the gap between Jira ticket management, Git version control, and AI-assisted coding (via Codex or Cursor).

By running a single command, this script fetches ticket details, sets up your Git branches, and prompts your AI coding assistant to plan and implement the required changes.

---

## 📋 Prerequisites

Before using this script, ensure you have the following installed and configured on your system:

1. **Git**: Installed and authenticated with your repository.
2. **Jira CLI**: You must have a Jira CLI installed (e.g., `ankitpokhrel/jira-cli`) and authenticated.
   - *Test this by running `jira issue view <ISSUE-ID>` in your terminal. It should return ticket details without prompting for a password.*
3. **AI Command Line Tools**: Depending on your preference, you need the CLI tool installed globally:
   - **Codex CLI**: Accessible via the `codex` command.
   - **Cursor/Agent CLI**: Accessible via the `agent` command.

---

## 🛠️ Installation & Setup

Install via Homebrew:

```bash
brew tap imaresss/jira_to_code
brew install jira_to_code
```

That's it — `jira_to_code` will be available system-wide immediately after installation.

---

## 💻 Usage & Functioning

Run the script in your terminal:

```bash
./jira_to_code
```

*(Or simply `jira_to_code` if you added it to your PATH.)*

### Command-Line Options

You can pass values via `getopts` to skip interactive prompts:

| Option | Description |
|--------|-------------|
| `-j ID` | Jira ticket ID (e.g., `PROJ-123`) |
| `-p PATH` | Project directory path (default: current directory) |
| `-b NAME` | Base branch name (default: current branch) |
| `-a N` | AI tool: `1` = Codex, `2` = Cursor (default: 1) |
| `-h` | Show help and exit |

**Examples:**

```bash
# Fully non-interactive
jira_to_code -j RS-126 -p /path/to/repo -b main -a 1

# Partially interactive (only Jira ID via CLI)
jira_to_code -j RS-126

# Fully interactive (unchanged behavior)
jira_to_code
```

Any option not provided via the command line will be prompted interactively.

### Interactive Prompts

The script will guide you through a series of prompts (for any values not provided via options):

| Prompt | Description | Default (Press Enter) |
|---|---|---|
| **Jira ID** | The Jira ticket key or full link (e.g., `PROJ-123` or `https://genbanext.atlassian.net/browse/RS-126`). Full URLs are automatically parsed to extract the ticket ID. | Required — cannot be left blank. |
| **Project Path** | The absolute path to your local Git repository. | Current directory. |
| **Base Branch** | The branch you want to branch off of. | Current active branch of the repository. |
| **AI Tool** | Which AI assistant you want to process the ticket (`1` Codex, `2` Cursor). | `1` (Codex). |
| **Additional Prompt** | Optional extra instructions appended to the AI prompt. | Skipped. |

---

## ⚙️ How It Works (Step-by-Step)

Once you provide the inputs, the script executes the following workflow automatically:

1. **Navigation**: Changes the directory to your specified Project Path.
2. **Base Setup**: Checks out your specified Base Branch (defaults to current branch) to ensure a clean starting point.
3. **Data Fetching**: Calls the Jira CLI to download the title, description, and details of the provided Jira ID.
4. **Feature Branching**: Creates and switches to a brand new branch named `feature/<Jira-ID>` (e.g., `feature/PROJ-123`).
5. **AI Execution**: Passes a highly specific prompt to your chosen AI tool via its dedicated module (`codex.sh` or `cursor.sh`). The AI is instructed to:
   - Read the Jira ticket context.
   - Analyze your current local codebase.
   - Output a step-by-step implementation plan.
   - Wait for your confirmation before writing the code.

---

## 🤖 Model Selection

After the AI tool is chosen, both Codex and Cursor offer an optional model selection step.

### For both tools:

```
Press Enter to continue with default model, or type 1 to select a model:
```

- **Press Enter** → proceeds immediately with the tool's default model.
- **Type `1`** → shows the model list and prompts for a selection.

---

### Codex Models

| # | Model |
|---|---|
| 1 | gpt-5.3-codex |
| 2 | gpt-5.2-codex |
| 3 | gpt-5.2 |
| 4 | gpt-5.1-codex-max |
| 5 | gpt-5.1-codex-mini |

After selecting a Codex model, you are also prompted to choose a **reasoning effort level**:

| Effort | Available for |
|---|---|
| Low | All models except codex-mini |
| Medium | All models |
| High | All models |
| Extra High | All models except codex-mini |

Press Enter at the effort prompt to skip and use the model's default effort.

---

### Cursor Models

Cursor models are fetched dynamically at runtime using `agent --list-models`, so the list always reflects what is available for your account. Press Enter to skip and use the currently active model. Selecting the model marked `(current)` also uses the default agent call.

---

## 🗂️ File Structure

```
jira_to_code_scripts/
├── jira_to_code.sh   # Main entry point — collects inputs, sets up git, calls AI module
├── codex.sh          # Codex module — model/effort selection and Codex CLI invocation
└── cursor.sh         # Cursor module — dynamic model listing and Cursor agent invocation
```

---

## 🌟 Example Run

```plaintext
$ jira_to_code
🚀 Welcome to jira_to_code!
----------------------------
Enter Jira ID or full link (e.g., PROJ-123 or https://genbanext.atlassian.net/browse/RS-126): PROJ-456
Enter Project Path [Press Enter for current dir]: 
Enter Base Branch [Press Enter for current branch]: 

Which AI tool would you like to use?
  1) Codex
  2) Cursor
Select tool (1 or 2) [Press Enter for 1]: 1
Add additional prompt text (optional, press Enter to skip): Please add unit tests for any new logic.
----------------------------
📂 Navigating to /Users/pulkitkedia/Documents/my-repo...
📍 Using current branch: develop
🌿 Checking out base branch: develop...
🔍 Fetching Jira ticket PROJ-456...
🔀 Switching to feature branch: feature/PROJ-456...

Press Enter to continue with default model, or type 1 to select a model: 1

Select a Codex model:
  1) gpt-5.3-codex
  2) gpt-5.2-codex
  3) gpt-5.2
  4) gpt-5.1-codex-max
  5) gpt-5.1-codex-mini
Select model (1-5) [Press Enter to skip]: 2

Select reasoning effort:
  1) Low
  2) Medium
  3) High
  4) Extra High
Select effort (1-4) [Press Enter to skip]: 3

🤖 Asking Codex to plan and implement...
[... AI tool takes over here ...]
✅ Success! Ticket PROJ-456 setup completed on branch feature/PROJ-456.
```
