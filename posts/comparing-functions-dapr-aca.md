## TL;DR

In this post I show

- (mainly) how .NET **Azure Functions** (in the 2 currently available hosting options on **Azure Container Apps**) can be compared to a ASP.NET Dapr application in terms of asynchronous messaging throughput
- some learnings when deploying the 3 variants on ACA (=Azure Container Apps):
  - Azure Functions in a container on ACA, applying KEDA scaling
  - Azure Functions on ACA, leaving scaling up to the platform
  - ASP.NET in a container on ACA using Dapr sidecar, apply KEDA scaling

> Although the [sample repo](https://github.com/KaiWalter/message-distribution) also contains a deployment option with **Azure Developer CLI**, I never was able to sustain stable deployment with this option while Azure Functions on Container Apps was in preview.

## Motivation

[Azure Container Apps hosting of Azure Functions](https://learn.microsoft.com/en-us/azure/azure-functions/functions-container-apps-hosting) is a way to host Azure Functions directly in Container Apps - additionally to App Service with and without containers. This offering also adds some Container Apps built-in capabilities like [KEDA](https://keda.sh/) scaling and the [Dapr](https://dapr.io/) microservices framework which would allow for mixing microservices workloads on the same environment with Functions.

Running a sufficiently big workload already with Azure Functions inside containers on Azure Container Apps for a while, I wanted to see how both variants compare in terms of features and above all : scaling.

With [another environment](https://customers.microsoft.com/en-us/story/1336089737047375040-zeiss-accelerates-cloud-first-development-on-azure-and-streamlines-order-processing) we heavily rely on **Dapr** for synchronous invocations as well as asynchronous message processing. Hence additionally I wanted to see whether one of the frameworks - Azure Functions host with its bindings or Dapr with its generic components and the sidecar architecture - substantially stands out in terms of throughput.

## Solution Overview

The test environment can be deployed from this [repo](https://github.com/KaiWalter/message-distribution) - `README.md` describes the steps required.

### Approach

To come to a viable comparision, I applied these aspects:

- logic for all contenders is written in **C# / .NET 7**
- all contenders need to process the **exact same volume** and structure of payloads - which is generated once
- test payload (10k messages by default) is send on a queue and **scheduled to exactly the same time** to force the contending stack, to deal with the amount at once
- both Functions variants are based on **.NET isolated worker**, as Functions on Container Apps only support this model
- all 3 variantes run staggered on the same Container Apps environment, hence same region, same nodes, same resources

### Solution Elements

- a `Generate` in Function App `testdata` generates a test data payload (e.g. with 10k orders) and puts it in a blob storage
- one of the `PushIngress...` functions in the very same Function App then can be triggered to schedule all orders at once on an ingress Service Bus queue - either for Functions or for Dapr
- each of the contestants has a `Dispatch` method which picks the payload for each order from the ingress queue, inspects it and puts it either on a queue for "Standard" or "Express" orders
- then for these order types there is a separate `Receiver` function which finally processes the dispatched message

![Solution overview showing main components](https://github.com/KaiWalter/message-distribution/blob/main/media/test-setup.png?raw=true)

C# project names and queues use a consistent coding for each contestant:

| code used for solution elements | implementation and deployment approach                                                                                             |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| **ACAF**                        | .NET [Azure Functions on ACA deployment](https://learn.microsoft.com/en-us/azure/azure-functions/functions-container-apps-hosting) |
| **DAPR**                        | ASP.NET with Dapr in a container on ACA                                                                                            |
| **FUNC**                        | .NET Azure Functions in a container on ACA                                                                                         |

### Limitations

- Only **Service Bus queues** are tested. Of course, a scenario like this can also be achieved with pub/sub Service Bus **topics** and subscriptions. In the enterprise workloads, where we apply this pattern, we however stick with queues as these allow a dedicated dead-lettering at each stage of the process - compared to topics, where moving messages from _dead-letter_ to _active_ results in all subscribers (if not explicitly filtered) receivng these messsages again.
- Currently not all capabilities of the contesting stacks - like Dapr bulk message processing - are maxed out. Hence there is obviously still some potential into improving individual throughput.

### Measuring Throughput

Throughput is measured by substracting the timestamp of the last message processed from the timestamp of the first message processed - for a given scheduling timestamp. A generic query to Application Insights with `$TESTPREFIX` representing one of the _codes_ above and `$SCHEDULE` refering to the scheduling timestamp for a particular test run:

```
query="requests | where cloud_RoleName matches regex '$TESTPREFIX(dist|recv)' | where name != 'Health' and name !startswith 'GET' | where timestamp > todatetime('$SCHEDULE') | where success == true | summarize count(),sum(duration),min(timestamp),max(timestamp) | project count_, runtimeMs=datetime_diff('millisecond', max_timestamp, min_timestamp)"
```

### Evaluating Scaling

While above query is used in the automated testing and recording process, I used this type of query ...

```
requests
| where cloud_RoleName startswith "func"
| where name != "Health"
| where timestamp > todatetime('2022-11-03T07:09:26.9394443Z')
| where success == true
| summarize count() by cloud_RoleInstance, bin(timestamp, 15s)
| render columnchart
```

... to see whether the platform / stack scales in an expected pattern, ...

![Regular scaling of Functions container](https://github.com/KaiWalter/message-distribution/blob/main/media/2023-08-08-scaling-func.png?raw=true)

... which pointed me to a strange scaling lag for Azure Functions on ACA:

![Lagged scaling for Functions on ACA](https://github.com/KaiWalter/message-distribution/blob/main/media/2023-08-08-scaling-acaf.png?raw=true)

Microsoft Product Group looked into this observation and provided an explanation in this [GitHub issue](https://github.com/Azure/azure-functions-on-container-apps/issues/33). When conducting the final battery of tests in October'23 this behavior was gone and Functions scaled as to be expected.

## Results

A first batch of tests in August'23 revealed no substantial disparity between the stacks:

![comparing runtimes](https://github.com/KaiWalter/message-distribution/blob/main/media/2023-08-08-results.png?raw=true)

To capture the final results in October'23, I ...

- upgraded dependencies of the .NET projects (e.g. to Dapr 1.11)
- switched from Azure Service Bus Standard Tier to Premium because of that throttling issue explained below, which imho gave the whole scneario a major boost

## Learnings and Gotchas

Appart from the plain throughput evaluation above, I want to add the issues I stumbled over along the way - I guess the real "meat" of this post:

### Dapr batching

Dapr input binding and pub/sub Service Bus components need to be set to values much higher than [the defaults](https://docs.dapr.io/reference/components-reference/supported-bindings/servicebusqueues/) to get a processing time better than Functions - keeping defaults shows Dapr E2E processing time almost factor 2 compared to Functions.

```
        {
          name: 'maxActiveMessages'
          value: '1000'
        }
        {
          name: 'maxConcurrentHandlers'
          value: '8'
        }
```

### Functions batching

Changing from single message dispatching to batched message dispatching and thus using batching `"MaxMessageBatchSize": 1000` did not have a positive effect - on the contrary: processing time was 10-20% longer.

_single message dispatching_

```csharp
        [FunctionName("Dispatch")]
        public void Run(
            [ServiceBusTrigger("q-order-ingress-func", Connection = "SERVICEBUS_CONNECTION")] string ingressMessage,
            [ServiceBus("q-order-express  {
    name: 'WEBSITE_SITE_NAME'
    value: appName
  }
ollector<ServiceBusMessage> outputExpressMessages,
            [ServiceBus("q-order-standard-func", Connection = "SERVICEBUS_CONNECTION")] ICollector<ServiceBusMessage> outputStandardMessages,
            ILogger log)
        {
            ArgumentNullException.ThrowIfNull(ingressMessage,nameof(ingressMessage));

            var order = JsonSerializer.Deserialize<Order>(ingressMessage);

            ArgumentNullException.ThrowIfNull(order,nameof(ingressMessage));
```

_batched_

```csharp
        [FunctionName("Dispatch")]
        public void Run(
            [ServiceBusTrigger("q-order-ingress-func", Connection = "SERVICEBUS_CONNECTION")] ServiceBusReceivedMessage[] ingressMessages,
            [ServiceBus("q-order-express-func", Connection = "SERVICEBUS_CONNECTION")] ICollector<ServiceBusMessage> outputExpressMessages,
            [ServiceBus("q-order-standard-func", Connection = "SERVICEBUS_CONNECTION")] ICollector<ServiceBusMessage> outputStandardMessages,
            ILogger log)-func", Connection = "SERVICEBUS_CONNECTION")] IC
        {
            foreach (var ingressMessage in ingressMessages)
            {
                var order = JsonSerializer.Deserialize<Order>(Encoding.UTF8.GetString(ingressMessage.Body));
                ArgumentNullException.ThrowIfNull(order, nameof(ingressMessage));
```

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

OK, but why? Reviewing [how Azure Service Bus Standard Tier is handling throttling](https://learn.microsoft.com/en-us/azure/service-bus-messaging/service-bus-throttling#what-are-the-credit-limits) and considering the approach of moving 10.000 messages at once from _scheduled_ to _active_ hints towards this easily crashing the credit limit applied in Standard Tier.