## Motivation

Since I first laid eyes and hands on [Dapr](https://dapr.io) with its creation in 2019, I have been fascinated by the potential of building distributed applications with it. The Dapr team has been working hard to make it easier to build microservices and distributed systems, and I wanted to explore how Dapr can be used to create agentic workflows.

![Original N8N flow downloading, transcribing and spawning actions on a voice recording](/images/dapr-agents-original-n8n-flow.png)

## Learnings

- when refactoring agents especially renaming or deleting them, be sure to flush or clean up the agent state store; otherwise orchestrator will still try to involve orphaned agents
- closely and repeatedly observe conversion flow to see where instructions need to be more precise or where the agent needs to be more capable
- when passing file paths in task message, wrap it
