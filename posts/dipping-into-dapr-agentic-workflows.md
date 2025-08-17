## Motivation

Since I first laid eyes and hands on [Dapr](https://dapr.io) when it was created in 2019, I have been fascinated by the potential of building distributed applications with it. The Dapr team has been working hard to make it easier to build microservices and distributed systems ever since. Workflows had been added with release [1.15](https://blog.dapr.io/posts/2025/02/27/dapr-v1.15-is-now-available/#dapr-workflow-stable) and AI agent support started showing up [in spring 2025](https://www.cncf.io/blog/2025/03/12/announcing-dapr-ai-agents/). When I learned about Dapr workflows and agents on this [episode](https://youtu.be/VLRg4TKtLBc) just recently, I wanted to explore how Dapr can be used to create agentic workflows.

I had been dabbling with some frameworks over the past few months - to one or the other degree:

- [Pydantic AI](https://github.com/pydantic/pydantic-ai)
- [Semantic Kernel](https://github.com/microsoft/semantic-kernel)
- [AutoGen](https://github.com/microsoft/autogen)

Nothing really stuck with me. The challenge I wanted to solve:

_I am out, mostly in the mornings for a walk or run, and I just want to drop a thought or a task immediately. Sometimes even complete sections of an upcoming presentation. Or rushing between meeting, the same: Just drop a voice recording and have it turned into a task or just as a note into my email inbox._

Finally with [n8n](https://n8n.io) I pushed myself into a working flow with a highly curated environment. I dropped that idea of developing the flow on my own as the value of having such a flow outweighed the learning experience.

![Original n8n flow downloading, transcribing and spawning actions on a voice recording](../images/dapr-agents-original-n8n-flow.png)

How it works:

- on my Android phone I use the paid version of _Easy Voice Recorder Pro_ which allows to automatically upload into a predefined _OneDrive_ folder (which is `/Apps/Easy Voice Recorder Pro`)
- the recording is downloaded by the n8n flow on a trigger, when a file is created in that folder
- before downloading, to be safe and not crash the transcription unnecessarily, the flow filters on `audio/x-wav` or `audio/mpeg` MIME types
- additionally the flow downloads a prompt text file from OneDrive which contains the instructions for classifying the intent in the transcription; I wanted to be on OneDrive, so I can modify it easily without having to touch the flow
- then transcribe using OpenAI Whisper API
- with the transcription and the prompt run through a model like `GPT-4.1-MINI`
- that classification step also has access to a simple tool - referenced in the prompt: a list of relevant person and other entity names to make the transcription more precise
- based on the intent resolved then either create a task (using a webhook, as I did not want to mess around in our corporate environment) or just send an email to my corporate-self with the plain transcription
- of course also housekeeping: copy (as moving was not supported) the file to a archive folder and delete the original file

That works pretty well. I especially liked the capability of n8n to copy runtime data of a certain execution into the editor, which makes mapping and debugging so much easier. I moved the cloud based flow so I could run it basically for free (download it, import it from file, rewire cloud credentials).

Enough of n8n. A nice environment to get started quickly - without a doubt.

## Value proposition of Dapr Agents and Workflows for me

This is what me got spending factor 3-4 more time into a Dapr based flow:

- I like the **code-first** approach with workflows and agents; for use cases we face in our company I additionally needed to understand what building and operating such a flow in a sustainable and scalable fashion entails
- with Dapr I get **resource abstraction** - switch easily between _state_ and _pub/sub_ resource providers, e.g. from Redis to Azure Cosmos DB or Azure Service Bus, even locally from Redis to SQlite if required
- with Dapr I get **observability** which I can hook easily into our environment
- with Dapr I achieve the desired **separation of concerns** between the workflow and the agents; I can develop and deploy them independently
- with Dapr I can **mix** in "classic" enterprise processing easily, I can mix languages among Dapr applications, e.g. Python for the agents and C# for the workflow

## What I wanted to do differently

As seen above I implemented a rather deterministic flow with n8n. I wanted to explore how I can use Dapr agents and workflows to create a more agentic workflow, which is more flexible and can adapt to the situation at hand - making scaling up and bringing in new components more easy. In essence this means:

1. polling on OneDrive, downloading and transcribing the voice recording runs in a deterministic workflow
2. transcript is then handed to LLM-orchestrated agents which have instructions to figure out what to do with the transcription
3. instead of funneling all information into the flow, I want agents to make use of **tools** (probably MCP servers in the future) to interact with the outside world; again here I think that Dapr can shine as I easily can wire up tools with other Dapr applications, either using pub/sub or service invocation

---

## A look into the codebase

The code can be found in my [GitHub repository](https://github.com/KaiWalter/dapr-agent-flow).

> BIG FAT DISCLAIMER: This is a work in progress, I am still learning and exploring the capabilities of Dapr agents and workflows. The code is not production-ready and should be used for educational purposes only.<br/>
> DISCLAIMER: Almost 95% of the code has been created with GitHub Copilot. I made this project into a "two birds, one stone" exercise as I was keen to created a larger codebase with AI support for a long time. I will share and link here learnings on my "me and my coding apprentice" journey some time in the future. Let's just say: For me as an occasional coder, not versed in Python really, it would not have been possible to achieve that amount of [function points](https://en.wikipedia.org/wiki/Function_point), a measure we kids used some decades ago to measure the size of a software project, without AI support.

### Top Level / Tier 1 Structure

The structure leans into structures provided by [quickstart samples](https://github.com/dapr/dapr-agents/tree/main/quickstarts). Some polishing is still required, but I wanted to get the code out there to get feedback and learnings from the community.

[Dapr Multi-App Run](https://docs.dapr.io/developing-applications/local-development/multi-app-dapr-run/multi-app-overview/) file `master.yaml` points to the top-level applications and entry points:

- **services/ui/authenticator** : a small web UI that redirects into a MS Entra ID login which on callback serializes the access and refresh tokens into a Dapr state store;
  from there token information is picked up to authenticate for OneDrive and OpenAI API calls by the other services;
  basic idea is to make the login once and let the workflow processes run in the background without further interaction
- **services/workflow/worker** : runs the main polling loop at a timed interval to kick off the workflow, and the workflows to come, with a pub/sub signal;
  with that I achieve some loose coupling between the workflow and the main loop (instead of using child workflows or alike)
- **services/workflow/worker_voice2action** : defines the deterministic steps of the main Voice-2-Action workflow;
  schedules a new instance when receiving pub/sub event from the main worker **services/workflow/worker**
- **services/intent_orchestrator/app** : bringing a LLM orchestrator for intent processing into standby, waiting for pub/sub events from **services/workflow/worker_voice2action** publish intent orchestrator activity
- **services/intent_orchestrator/agent_tasker** : participating in above orchestration as a utility agent which delivers information required for the flow like the transcript or time zone information
- **services/intent_orchestrator/agent_office_automation** : participating in above orchestration to fulfill all tasks which connect the flow to office automation, like creating tasks or sending emails
- **services/ui/monitor** : a small console app listening to and printing the LLM orchestration broadcast messages to allow for a better understanding of the flow; this is absolutely required to fine-tune the instructions to the orchestrator and the agents

### Tier 2 Elements

- **workflows/voicetoaction / voice2action_poll_orchestrator** : orchestrating the activities to list the files on OneDrive, marking new files and handing of each single file to child workflow ...
- **workflows/voicetoaction / voice2action_per_file_orchestrator** : ... orchestrating in sequential order: download recording, transcription, publish to intent workflow and then archive the file

### Tier 3 Elements

On this level in folder **activities** are workflow activities defined in modules which are referenced by deterministic workflows.

### Tier 4 Elements

Folder **services** directly contains helper services which are used by workflow activities or agents.

### Other Elements

Folder **components** holds all Dapr resource components used by all applications. Important to note is, that **state stores are segregated for their purpose**: for workflow state, for agent state and for token state. This is required as these state types require different configuration for prefixing state keys and the ability to hold actors.

Folder **models** contains common model definitions used by the workflow elements and agents.

### PRD / requirements

As stated above, I drove **GitHub Copilot** for the majority of work. For that, most of the time, when not falling back into old habits, I used **voice2action-requirements.md** PRD file to invoke feature implementation. So most of my intentions I had with the flow are also documented there.

### start.sh

This script helps me to start the process with a clean state which makes debugging various issues, especially in the agent instructions sphere much easier.

---

## Learnings

Some other points I'd like to convey:

- compared to the n8n flow, where one prompt yielded a structured intent and classification, it took some calibration on my end to balance out instructions handed to the orchestrator and the agents
- when refactoring agents, especially renaming or deleting them, be sure to flush or clean up the agent state store; otherwise orchestrator will still try to involve orphaned agents
- closely and repeatedly observe conversation flow to see where instructions need to be more precise or where the agent needs to be more capable
- when passing file paths in task message, wrap it in something like square brackets - just separating with a blank from regular instructions caused that file path sometimes could not be resolved correctly

## Other Dapr related posts

- [How to tune Dapr bulk publish/subscribe for maximum throughput](https://dev.to/kaiwalter/how-to-tune-dapr-bulk-publishsubscribe-for-maximum-throughput-40dd)
- [Comparing throughput of Azure Functions vs Dapr on Azure Container Apps](https://dev.to/kaiwalter/comparing-azure-functions-vs-dapr-on-azure-container-apps-2noh)
- [Combining Dapr with a backend WebAssembly framework - Taking Spin for a spin on AKS](https://dev.to/kaiwalter/taking-spin-for-a-spin-on-aks-2lf1)

## Conclusion

For me the **versatility of Dapr** for such scenarios seems tangible. I now need to operate it for a while. Add observability and surely more resilience. Also adding some more intents like "analyze this topic for me and send me a report" will show, whether my assumptions regarding scalability and flexibility hold up.
