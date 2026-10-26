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

## Choosing a model for each agent

Pick the model for the task; never give every agent Opus by default. Set `model` explicitly on every Agent call. The smallest model that can do the job well is the right one.

| Model | Use it for, in this repository |
| --- | --- |
| **Haiku** | Extracting compiler errors or failing tests from CI logs; listing commands, macro functions or option keys from ImageJ's sources; turning gap reports into checklists; checking release assets; simple renames and formatting. |
| **Sonnet** (the default) | Porting well-specified ImageJ commands, file formats and macro functions with parity tests; Mac app features; CI fixes; merges with ordinary conflicts; a gap audit of one area. |
| **Opus** (only where depth pays off) | Bug hunts and adversarial reviews; the final comparison with Fiji; models that cut across modules, such as overlays, ShapeRoi or the app session; ports whose numbers are hard to match exactly, such as EDM, FFT or JPEG's IDCT; untangling two agents' overlapping work. |

**Spending tokens well**
- Brief an agent with only what its task needs: the goal, the files, the commands to run and the report wanted. Never the conversation.
- Give each agent a scope that doesn't overlap another's, so no work is done twice or has to be merged by hand.
- Continue an agent that stopped (SendMessage) instead of starting a new one.
- Do a handful of tool calls yourself rather than delegating them.
- Have agents return conclusions, not file dumps or logs.
