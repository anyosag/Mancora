# Working on Mancora with Claude

## Agent routing

Act as an orchestrator: classify each task, then do it yourself or hand it to a sub-agent at the matching tier. With the Agent tool, the tier is its `model` parameter (`haiku`, `sonnet` or `opus`).

**Classify before acting.** State the tier first, then the approach.

| Tier | Scope | How to work |
| --- | --- | --- |
| **Haiku**: high-volume, rapid, bounded | Data classification, JSON extraction, simple formatting, file globbing, quick text filtering | Compact prompts; fast execution with minimal token overhead. |
| **Sonnet**: core reasoning, coding and tool use | Standard software engineering, multi-step code generation, technical analysis, tool-calling loops, general problem-solving | Reason step by step, and be clear about the tool calls and their inputs before acting. |
| **Opus**: deep architecture, review, long-horizon work | Complex system design, adversarial code review, multi-file refactoring, final quality sign-off | Plan in depth, critique your own work, and evaluate edge cases. |

**Execution rules**
- **Delegate with only the context the sub-task needs.** Pass the specific files, facts and goal, not the whole conversation history.
- **Plan, act, verify.** State the approach, make the tool or sub-agent call, then check the result against the user's goal before moving on.

In this repository:
- **Opus:** porting ImageJ/Fiji code with exact parity, bug hunts, and reviews or merges of agent work.
- **Sonnet:** ordinary features, fixes, and CI repairs.
- **Haiku:** sweeps such as listing commands or extracting tables from ImageJ's sources.
