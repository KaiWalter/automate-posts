## TL;DR

What can be seen in this post:

- use a Load Balancer combined with a small sized VM scaleset (VMSS) equiped with **iptables** to forward incoming connections to 2 IP addresses which represent 2 on-premise servers; this installation is placed in a hub network that can be shared amount several spokes
- link this Load Balancer to another virtual network - without virtual network peering - by utilizing Private Link Service and a Private Endpoint which is placed in a spoke network
- use Azure Container Instances to connect into hub or spoke networks and test connections

## Context

For a scenario within a corporate managed virtual network, I [private linked the Azure Container Apps environment with its own virtual network and non-restricted IP address space](https://dev.to/kaiwalter/preliminary-private-linking-an-azure-container-app-environment-3cnf) (here Spoke virtual network) to the corporate Hub virtual network.

![Azure Container Apps environment private linked into a corporate managed virtual network with limited IP address space](https://dev-to-uploads.s3.amazonaws.com/uploads/articles/ruketol7klgmhth52u2e.png)

> _back then, there was no official icon for Container Apps Environments available, hence I used an AKS icon_

One challenge that had to be solved back then is how to let the workloads running in Azure Container Apps environment call back into an API Management instance in the Hub virtual network. To achieve that I [private linked the Application Gateway, that forwards to the API Management instance, into the Spoke virtual network](https://dev.to/kaiwalter/use-azure-application-gateway-private-link-configuration-for-an-internal-api-management-1d6o):

![API Management private linked back to Spoke virtual network over Application Gateway and a Private Endpoint](https://dev-to-uploads.s3.amazonaws.com/uploads/articles/4b5i7ln4k7on0nou1cwu.png)

## A New Challenge

Just recently a new challenge came up: We needed to forward TCP traffic on a specific port to 2 specific - usually load balanced - servers in a downstream / connected on-premise network.

The first reflex was to try to put both IP addresses into a backend pool of a Load Balancer in the Hub virtual network. Then trying to establish a Private Endpoint in the Spoke virtual network to allow traffic from Azure Container Apps environment over private linking into the Load Balancer and then to the downstream servers. However some [limitations](https://learn.microsoft.com/en-us/azure/load-balancer/backend-pool-management#limitations) got in the way of this endeavor:

> Limitations
> - IP based backends can only be used for Standard Load Balancers
> - The backend resources must be in the same virtual network as the load balancer for IP based LBs
> - A load balancer with IP based Backend Pool can’t function as a Private Link service
> - ...

## Going Down the Rabbit Hole

As I usually _"Don't Accept the Defaults" (Abel Wang)_ or just am plain and simple stubborn, I tried it anyway - which in its neat way also provided some learnings, I otherwise would have missed.

To let you follow along I created a [sample repo](https://github.com/KaiWalter/azure-private-link-port-forward) which allows me to spin up a examplary environment using [Azure Developer CLI](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/overview) and [Bicep](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/overview?tabs=bicep).

> I actually like using **`azd`** together with **Bicep** for simple Proof-of-Concept like scenarios as I can easily `azd up` and `azd down` the environment without having to deal with state like with other IaC stacks.

**Learning 1:** I was not able to bring up the Load Balancer directly linked with the server IP addresses with [Bicep](https://github.com/KaiWalter/azure-private-link-port-forward/blob/main/infra/modules/loadbalancer/loadbalancer.bicep) in one go. [Deployment succeeded without error but backend pool just was not configured](https://stackoverflow.com/questions/75910542/backendaddresspool-in-azure-load-balancer-with-only-ip-addresses-does-not-deploy).

**Learning 2:** Deploying with CLI configured the Load Balancer backend pool correctly ... but forwarding did not work, because ...

```shell
source <(azd env get-values)

az network lb delete -g $RESOURCE_GROUP_NAME --name ilb-$RESOURCE_TOKEN

az network lb create -g $RESOURCE_GROUP_NAME --name ilb-$RESOURCE_TOKEN --sku Standard \
--backend-pool-name direct \
--subnet $(az network vnet subnet show -g $RESOURCE_GROUP_NAME -n shared --vnet-name vnet-hub-$RESOURCE_TOKEN --query id -o tsv)

az network lb probe create -g $RESOURCE_GROUP_NAME --lb-name ilb-$RESOURCE_TOKEN -n direct --protocol tcp --port 8000

az network lb address-pool create -g $RESOURCE_GROUP_NAME --lb-name ilb-$RESOURCE_TOKEN -n direct \
--backend-address name=server65 ip-address=192.168.42.65 \
--backend-address name=server66 ip-address=192.168.42.66 \
--vnet $(az network vnet show -g $RESOURCE_GROUP_NAME  -n vnet-hub-$RESOURCE_TOKEN --query id -o tsv)

az network lb rule create -g $RESOURCE_GROUP_NAME --lb-name ilb-$RESOURCE_TOKEN -n direct --protocol tcp \
--frontend-ip LoadBalancerFrontEnd --backend-pool-name direct \
--frontend-port 8000 --backend-port 8000 \
--probe direct

az network lb show -g $RESOURCE_GROUP_NAME --name ilb-$RESOURCE_TOKEN
```

> `source <(azd env get-values)` sources all `main.bicep` output values generated by `azd up` or `azd infra create` as variables into the running script

**Learning 3:** ... specifying IP addresses together with a virtual network in the backend pool is intended for the Load Balancer to hook up the NICs/Network Interface Cards of Azure resources later automatically when these NICs get available. It is not intended for some generic IP addresses.

Anyway Azure Portal did not allow to create a Private Link Service on a Load Balancer with IP address configured backend pool. So it would not have worked for my desired scenario anyway.

## Other Options

- **Virtual Network Peering** Hub and Spoke is not an option as we
  - do not want to mix up corporate IP address ranges with the arbitrary IP addresses ranges of the various Container Apps virtual networks
  - want to avoid BGP/Border Gateway Protocol mishaps at any cost
- with a recently [**reduced required subnet size** for Workload profiles](https://learn.microsoft.com/en-us/azure/container-apps/networking#subnet) moving **Azure Container Apps environment** back to corporate IP address space would have been possible, but I did not want to give up this extra level of isolation this separation based on Private Link in and out gave us

## Bring In some IaaS and **iptables** magic



![Network diagram showing connection from Private Endpoint over Private Link Service, Load Balancer to on premise Servers](../images/private-link-port-forward.png)