## TL;DR

In this post I show

- how to deploy Azure Functions on **Azure Container Apps** with **Bicep**
- how to deploy Azure Functions in containers on **Azure Container Apps** with **Bicep**
- how both variants handle scaling and how that impacts throughput for a simple queue based message distribution scenario
- how scaling and throughput compares to a plain ASP.NET **Dapr** application

> Although the [sample repo](https://github.com/KaiWalter/message-distribution) contains also a deployment option with **Azure Developer CLI**, I never was able to sustain stable deployment with this option while Azure Functions on Container Apps was in preview.

## Motivation

[Azure Container Apps hosting of Azure Functions](https://learn.microsoft.com/en-us/azure/azure-functions/functions-container-apps-hosting) is a way to host Azure Functions directly in Container Apps - additionally to App Service with and without containers. This offering also adds some Container Apps built-in capabilities like [KEDA](https://keda.sh/) scaling and the [Dapr](https://dapr.io/) microservices framework which would allow for mixing microservices workloads on the same environment with Functions.

Running a sufficiently big workload already with Azure Functions inside containers on Azure Container Apps for a while, I wanted to see how both variants compare in terms of features and above all : scaling.

With [another environment](https://customers.microsoft.com/en-us/story/1336089737047375040-zeiss-accelerates-cloud-first-development-on-azure-and-streamlines-order-processing) we heavily rely on **Dapr** for synchronous as well as asynchronous invocations. Hence additionally I wanted to see whether one of the frameworks - Azure Functions host with its bindings or Dapr with its generic components and the sidecar architecture - adds too much baggage in terms of throughput.

## Solution Overview

The exemplary environment can be deployed either with **Azure Developer CLI** or **Azure CLI** from this [repo](https://github.com/KaiWalter/message-distribution).

### Approach

- a `Generate` in Function App `testdata` generates a test data payload (e.g. with 10k orders) and puts it in a blob storage
- one of the `PushIngress...` functions in the same Function App then can be triggered to schedule all orders at once on an ingress Service Bus queue - either for Functions or for Dapr
- each of the contestants has a `Dispath` method which picks the payload for each order from the ingress queue, inspects it and puts it either on a queue for "Standard" or "Express" orders

![Solution overview showing main components](https://github.com/KaiWalter/message-distribution/blob/main/media/test-setup.png?raw=true)

---

## Gotchas

### Functions not processing all messages

| scheduleTimeStamp            | variant | total message count | duration ms |
| ---------------------------- | ------- | ------------------- | ----------- |
| 2023-10-08T10:30:02.6868053Z | ACAFQ   | 20000               | 161439      |
| 2023-10-08T10:39:04.8862227Z | DAPRQ   | 20000               | 74056       |
| 2023-10-08T10:48:03.0727583Z | FUNCQ   | 19890 **<---**      | 81700       |
| 2023-10-08T10:57:43.6880713Z | ACAFQ   | 20000               | 146270      |
| 2023-10-08T11:06:50.3649399Z | DAPRQ   | 20000               | 95292       |
| 2023-10-08T11:15:49.0727755Z | FUNCQ   | 20000               | 85025       |
| 2023-10-08T11:25:05.3765606Z | ACAFQ   | 20000               | 137923      |
| 2023-10-08T11:34:03.8680341Z | DAPRQ   | 20000               | 67746       |
| 2023-10-08T11:43:11.6807872Z | FUNCQ   | 20000               | 84273       |
| 2023-10-08T11:52:36.0779390Z | ACAFQ   | 19753 **<---**      | 142073      |
| 2023-10-08T12:01:34.9800080Z | DAPRQ   | 20000               | 55857       |
| 2023-10-08T12:10:34.5789563Z | FUNCQ   | 20000               | 91777       |
| 2023-10-08T12:20:03.5812046Z | ACAFQ   | 20000               | 154537      |
| 2023-10-08T12:29:01.8791564Z | DAPRQ   | 20000               | 87938       |
| 2023-10-08T12:38:03.6663978Z | FUNCQ   | 19975 **<---**      | 78416       |

Looking at the queue items triggering `distributor` logic ...

```
requests
| where source startswith "sb-"
| where cloud_RoleName endswith "distributor"
| summarize count() by cloud_RoleName, bin(timestamp,15m)
```

| cloud_RoleName  | timestamp [UTC]            | count\_       |
| --------------- | -------------------------- | ------------- |
| acafdistributor | 10/8/2023, 10:30:00.000 AM | 10000         |
| funcdistributor | 10/8/2023, 10:45:00.000 AM | 9890 **<---** |
| acafdistributor | 10/8/2023, 10:45:00.000 AM | 10000         |
| funcdistributor | 10/8/2023, 11:15:00.000 AM | 10000         |
| acafdistributor | 10/8/2023, 11:15:00.000 AM | 10000         |
| funcdistributor | 10/8/2023, 11:30:00.000 AM | 10000         |
| acafdistributor | 10/8/2023, 11:45:00.000 AM | 10000         |
| funcdistributor | 10/8/2023, 12:00:00.000 PM | 10000         |
| acafdistributor | 10/8/2023, 12:15:00.000 PM | 10000         |
| funcdistributor | 10/8/2023, 12:30:00.000 PM | 9975 **<---** |
| acafdistributor | 10/8/2023, 12:45:00.000 PM | 10000         |

... which is strange, considering that the respective `PushIngressFuncQ` (at ~12:30) sent exactly 10.000 messages into the queue.

Checking how much Service Bus dependencies have been generated for a particular request:

```
dependencies
| where operation_Id == "cbc279bb851793e18b1c7ba69e24b9f7"
| where operation_Name == "PushIngressFuncQ"
| where type == "Queue Message | Azure Service Bus"
| summarize count()
```

So it seems, that between sending messages into and receiving messages from a queue, messages get lost - which is not acceptable for a scenario that assumed to be enterprise grade reliable. Checking Azure Service Bus metrics reveals, that the namespace is throttling requests:

![Graph showing that Azure Service Bus Standard is throttling](../images/comparing-functions-dapr-aca-throttling.png)

OK, but why? Reviewing [how Azure Service Bus Standard Tier is handling throttling](https://learn.microsoft.com/en-us/azure/service-bus-messaging/service-bus-throttling#what-are-the-credit-limits) and considering the approach of moving 10.000 messages at once from _scheduled_ to _active_ hints towards, that this is easily crashing the credit limit applied in Standard Tier.
