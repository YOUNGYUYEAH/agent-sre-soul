---
name: azure
description: Azure CLI 运维速查（订阅与 Resource Graph、Entra 组与角色授权、AKS 创建/节点池/维护窗口/监控/ACR、网络 VNet/NSG/LB/NAT/公网 IP/Traffic Manager、VM 与磁盘、存储账户），已修正原片段错误参数并标注危险操作
metadata:
  type: reference
---

# Azure CLI 速查

占位符：`<SUB_ID>` `<RG>` `<LOCATION>` `<CLUSTER>` `<NODEPOOL>` `<VNET>` `<SUBNET>` `<VM>` `<ACCOUNT>` `<NSG>` `<PIP>`。
本地验证版本 az 2.81。`!!` 为破坏性操作。az 支持参数前缀缩写，拼错的长参数可能被**静默匹配成别的参数**（例：`--name` 会被当成 `--namespace`），务必写全。

## 1. 订阅与全局资源搜索

```bash
az account show -o table
az account set -s <SUB_ID>          # 操作前先确认订阅，最常见的误操作源
az group list -o table
```

Resource Graph（需 `resource-graph` 扩展，跨订阅、秒级返回，比逐个 list 快得多）：
```bash
# 按关键字模糊搜任意资源（KQL 中字符串用单引号，// 是注释）
KW='<KEYWORD>'
az graph query -q "
  Resources
  | where name contains '$KW' or tostring(properties) contains '$KW'
  | project name, type, resourceGroup, location
  // | where type in~ ('microsoft.containerservice/managedclusters')
" --query data -o table

# VM 平台侧事件（宿主机维护、重启、降级的原因）
az graph query -q '
  HealthResources
  | where type =~ "microsoft.resourcehealth/resourceannotations"
  | extend VM=tostring(properties.targetResourceId), T=todatetime(properties.occurredTime),
           Annotation=tostring(properties.annotationName), Reason=tostring(properties.reason),
           Category=tostring(properties.category), Summary=tostring(properties.summary)
  | where VM has "/virtualMachines/"
  | order by T desc
  | project T, VM, Annotation, Category, Reason, Summary' --query data -o json

# 当前不可用/降级的资源
az graph query -q '
  HealthResources
  | where type =~ "microsoft.resourcehealth/availabilitystatuses"
  | extend R=tostring(properties.targetResourceId), State=tostring(properties.availabilityState)
  | where State != "Available"
  | project R, State' --query data -o table

# 进行中的 Azure 区域服务故障（怀疑是云厂商问题时第一时间查）
az graph query -q '
  ServiceHealthResources
  | where type =~ "Microsoft.ResourceHealth/events"
  | extend eventType=properties.EventType, status=properties.Status, title=properties.Title,
           trackingId=properties.TrackingId, start=todatetime(properties.ImpactStartTime)
  | where eventType == "ServiceIssue" and status == "Active"
  | project title, status, start, trackingId' --query data -o table
```

## 2. Entra ID 组与 RBAC 授权

```bash
az ad group list --display-name <GROUP> --query "[].{Name:displayName,ID:id}" -o table
GROUP_ID=$(az ad group show --group <GROUP> --query id -o tsv)
USER_ID=$(az ad user show --id <UPN> --query id -o tsv)
az ad group member add    --group "$GROUP_ID" --member-id "$USER_ID"
az ad group member remove --group "$GROUP_ID" --member-id "$USER_ID"

# 某主体被授予了哪些角色（--all 跨所有 scope）
az role assignment list --assignee <OBJECT_ID> --all \
  --query '[].{Principal:principalName, Role:roleDefinitionName, Scope:scope}' -o table
```

给组授予 AKS 权限（Entra 集成 + Azure RBAC 模式）：
```bash
CLUSTER_ID=$(az aks show -g <RG> -n <CLUSTER> --query id -o tsv)
# 1) 拉取 kubeconfig 的基本权限（必需）
az role assignment create --assignee-object-id "$GROUP_ID" --assignee-principal-type Group \
  --role "Azure Kubernetes Service Cluster User Role" --scope "$CLUSTER_ID"
# 2a) 集群级管理
az role assignment create --assignee-object-id "$GROUP_ID" --assignee-principal-type Group \
  --role "Azure Kubernetes Service RBAC Admin" --scope "$CLUSTER_ID"
# 2b) 仅某命名空间读写（不能管理 Role/RoleBinding；CRD 资源需另建自定义角色授权）
az role assignment create --assignee-object-id "$GROUP_ID" --assignee-principal-type Group \
  --role "Azure Kubernetes Service RBAC Writer" --scope "$CLUSTER_ID/namespaces/<NAMESPACE>"
# 撤销
az role assignment delete --assignee "$GROUP_ID" --role "<ROLE>" --scope "$CLUSTER_ID"
```
- 用 `--assignee-object-id` + `--assignee-principal-type` 可免去 Graph 查询，在权限受限或复制延迟时更稳。
- 角色分配生效有几分钟延迟；用户需重新 `az login` / 刷新 kubelogin token。

## 3. AKS

### 查看与凭证
```bash
az aks list -o table
az aks show -g <RG> -n <CLUSTER> -o json
az aks get-credentials -g <RG> -n <CLUSTER> [--overwrite-existing]   # 用户凭证（Entra，配合 kubelogin）
az aks get-credentials -g <RG> -n <CLUSTER> --admin                  # 本地管理员证书，绕过 Entra 审计；禁用本地账户时不可用
az aks nodepool list -g <RG> --cluster-name <CLUSTER> -o table
```

### 创建集群（Azure CNI Overlay 模板）
规划要点：
- 节点子网只给节点用（Overlay 下 Pod 不占 VNet IP），Pod CIDR / Service CIDR 不能与 VNet、对端网络、本地网络重叠。
- Service CIDR 不可用：169.254.0.0/16、172.30.0.0/16、172.31.0.0/16、192.0.2.0/24；DNS IP 取 Service CIDR 内的第 10 个地址（且不能是 .1）。
- 版本先查：`az aks get-versions -l <LOCATION> -o table`。

```bash
az account set -s <SUB_ID>
az network vnet subnet create -g <RG> --vnet-name <VNET> -n <SUBNET> --address-prefixes <SUBNET_CIDR>
SUBNET_ID=$(az network vnet subnet show -g <RG> --vnet-name <VNET> -n <SUBNET> --query id -o tsv)

az aks create -g <RG> -n <CLUSTER> -l <LOCATION> \
  --kubernetes-version <K8S_VERSION> --tier standard \
  --enable-managed-identity \
  --network-plugin azure --network-plugin-mode overlay \
  --pod-cidr <POD_CIDR> --service-cidr <SVC_CIDR> --dns-service-ip <DNS_IP> \
  --vnet-subnet-id "$SUBNET_ID" \
  --load-balancer-sku standard --outbound-type loadBalancer \
  --os-sku AzureLinux --nodepool-name system --node-vm-size <VM_SIZE> \
  --enable-cluster-autoscaler --node-count 2 --min-count 2 --max-count 4 \
  --zones 1 2 3 --max-pods 30 \
  --enable-oidc-issuer --enable-workload-identity \
  --auto-upgrade-channel patch --node-os-upgrade-channel NodeImage \
  --generate-ssh-keys
```
- 使用自建 VNet/子网或其他 RG 的公网 IP 时，集群身份需要对该子网/RG 有 `Network Contributor`（见下文“跨 RG 授权”）。

### 用户节点池
```bash
# 参考已有节点池的关键参数
az aks nodepool list -g <RG> --cluster-name <CLUSTER> \
  --query "[].{name:name,mode:mode,vmSize:vmSize,osSku:osSku,min:minCount,max:maxCount,maxPods:maxPods,maxSurge:upgradeSettings.maxSurge,scaleDown:scaleDownMode,zones:availabilityZones}" -o json

az aks nodepool add -g <RG> --cluster-name <CLUSTER> -n <NODEPOOL> \
  --mode User --node-vm-size <VM_SIZE> --os-sku AzureLinux \
  --enable-cluster-autoscaler --node-count 1 --min-count 1 --max-count 2 \
  --zones 1 2 3 --max-pods 30 --max-surge 10% --scale-down-mode Delete \
  --vnet-subnet-id "$SUBNET_ID"
```
节点池名：小写字母数字，Linux 最长 12 字符。

### 伸缩
```bash
az aks nodepool show -g <RG> --cluster-name <CLUSTER> -n <NODEPOOL> --query "{auto:enableAutoScaling,min:minCount,max:maxCount,count:count}" -o table
az aks nodepool update -g <RG> --cluster-name <CLUSTER> -n <NODEPOOL> --update-cluster-autoscaler --min-count <MIN> --max-count <MAX>   # 已开启时改范围
az aks nodepool update -g <RG> --cluster-name <CLUSTER> -n <NODEPOOL> --disable-cluster-autoscaler
az aks nodepool update -g <RG> --cluster-name <CLUSTER> -n <NODEPOOL> --enable-cluster-autoscaler --min-count <MIN> --max-count <MAX>
# 手动伸缩：必须先关闭 autoscaler，否则报错
az aks nodepool scale -g <RG> --cluster-name <CLUSTER> -n <NODEPOOL> --node-count 3
```

### 集成 ACR / 托管 Prometheus
```bash
az acr list -o table
az aks update -g <RG> -n <CLUSTER> --attach-acr <ACR_NAME>      # 给 kubelet 身份授予 AcrPull，需要 Owner/UAA 权限
az aks check-acr -g <RG> -n <CLUSTER> --acr <ACR_NAME>.azurecr.io   # 验证节点能否拉取

az resource list --resource-type Microsoft.Monitor/accounts -o table
AMW_ID=$(az resource show -g <RG> --resource-type Microsoft.Monitor/accounts -n <AMW_NAME> --query id -o tsv)
az aks update -g <RG> -n <CLUSTER> --enable-azure-monitor-metrics --azure-monitor-workspace-resource-id "$AMW_ID"
az aks show -g <RG> -n <CLUSTER> --query azureMonitorProfile.metrics.enabled -o tsv
```

### 维护窗口（自动升级 / 节点镜像）
两个固定名称：`aksManagedAutoUpgradeSchedule`（K8s 版本）、`aksManagedNodeOSUpgradeSchedule`（节点 OS 镜像）。窗口至少 4 小时。
```bash
az aks maintenanceconfiguration list -g <RG> --cluster-name <CLUSTER> -o table
az aks maintenanceconfiguration show -g <RG> --cluster-name <CLUSTER> -n aksManagedAutoUpgradeSchedule

# 每 N 个月第二个周日 00:00 UTC，持续 4 小时
az aks maintenanceconfiguration add -g <RG> --cluster-name <CLUSTER> \
  -n aksManagedAutoUpgradeSchedule --schedule-type RelativeMonthly \
  --day-of-week Sunday --week-index Second --interval-months 6 \
  --duration 4 --start-time 00:00 --utc-offset +00:00 --start-date <YYYY-MM-DD>
az aks maintenanceconfiguration add -g <RG> --cluster-name <CLUSTER> \
  -n aksManagedNodeOSUpgradeSchedule --schedule-type RelativeMonthly \
  --day-of-week Sunday --week-index Second --interval-months 1 \
  --duration 4 --start-time 00:00 --utc-offset +00:00 --start-date <YYYY-MM-DD>
```
注意：`--auto-upgrade-channel patch` 时升级间隔过长（如 6 个月）可能跟不上 AKS 版本支持周期，需结合版本生命周期评估。

### 跨 RG 授权（例如使用其他 RG 的公网 IP / 子网）
```bash
PRINCIPAL_ID=$(az aks show -g <RG> -n <CLUSTER> --query identity.principalId -o tsv)   # 控制面托管身份的对象 ID（不是 clientId）
TARGET_RG_ID=$(az group show -n <TARGET_RG> --query id -o tsv)
az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
  --role "Network Contributor" --scope "$TARGET_RG_ID"
az role assignment list --assignee "$PRINCIPAL_ID" --scope "$TARGET_RG_ID" -o table
```

```bash
# !! 删除集群（不可恢复；--yes 跳过确认）
az aks delete -g <RG> -n <CLUSTER> --yes --no-wait
```

## 4. 网络

### VNet / 对等互联
```bash
az network vnet list -o table
az network vnet subnet list -g <RG> --vnet-name <VNET> -o table
# 对等互联必须两端各建一条
A_ID=$(az network vnet show -g <RG_A> -n <VNET_A> --query id -o tsv)
B_ID=$(az network vnet show -g <RG_B> -n <VNET_B> --query id -o tsv)
az network vnet peering create -g <RG_B> --vnet-name <VNET_B> -n b-to-a --remote-vnet "$A_ID" --allow-vnet-access
az network vnet peering create -g <RG_A> --vnet-name <VNET_A> -n a-to-b --remote-vnet "$B_ID" --allow-vnet-access
az network vnet peering list -g <RG_A> --vnet-name <VNET_A> -o table    # peeringState 应为 Connected
```
对等不可传递；地址空间重叠无法建立。

### NSG：定位 VM 生效的规则
NIC 和子网都可以挂 NSG，入站流量需两层都放行。
```bash
NIC_ID=$(az vm show -g <RG> -n <VM> --query 'networkProfile.networkInterfaces[0].id' -o tsv)
az network nic show --ids "$NIC_ID" --query networkSecurityGroup.id -o tsv          # NIC 级 NSG
SUBNET_ID=$(az network nic show --ids "$NIC_ID" --query 'ipConfigurations[0].subnet.id' -o tsv)
az network vnet subnet show --ids "$SUBNET_ID" --query networkSecurityGroup.id -o tsv   # 子网级 NSG
az network nic list-effective-nsg --ids "$NIC_ID"     # 合并后实际生效规则（VM 需运行中）

az network nsg rule list -g <RG> --nsg-name <NSG> -o table
# priority 100-4096，越小越优先；多个端口/前缀空格分隔
az network nsg rule create -g <RG> --nsg-name <NSG> -n <RULE> \
  --priority <PRIORITY> --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes <SRC_CIDR> --source-port-ranges '*' \
  --destination-address-prefixes '*' --destination-port-ranges <PORT1> <PORT2>
az network nsg rule delete -g <RG> --nsg-name <NSG> -n <RULE>
```
源地址尽量收敛到具体网段/Service Tag，避免 `'*'` 全放通。

### 公网 IP
```bash
az network public-ip list -g <RG> -o table
az network public-ip create -g <RG> -n <PIP> --sku Standard --allocation-method Static --zone 1 2 3   # 区域冗余，创建后不可改 zone
az network public-ip show -g <RG> -n <PIP> --query "{id:id, ip:ipAddress}" -o table
az network public-ip update -g <RG> -n <PIP> --dns-name <LABEL>      # 生成 <LABEL>.<region>.cloudapp.azure.com
az network public-ip delete -g <RG> -n <PIP>                          # !! 释放后 IP 无法找回
```

### 负载均衡器（AKS）
```bash
NODE_RG=$(az aks show -g <RG> -n <CLUSTER> --query nodeResourceGroup -o tsv)
az network lb show -g "$NODE_RG" -n kubernetes
az network lb frontend-ip list -g "$NODE_RG" --lb-name kubernetes -o table
```
AKS 节点资源组（MC_*）里的 LB 由云控制器管理，手工增删 frontend 可能被回收或冲突。给 Service 指定固定公网 IP 应使用 Service 注解：
`service.beta.kubernetes.io/azure-pip-name: <PIP>`（IP 在其他 RG 时再加 `service.beta.kubernetes.io/azure-load-balancer-resource-group: <PIP_RG>`，并给集群身份授权）。

### NAT 网关（固定出口 IP / 解决 SNAT 端口耗尽）
```bash
az network nat gateway list -o table
az network nat gateway create -g <RG> -n <NATGW> -l <LOCATION> --public-ip-addresses <PIP> --idle-timeout 10
az network vnet subnet update -g <RG> --vnet-name <VNET> -n <SUBNET> --nat-gateway <NATGW>

# 扩容出口 IP：没有 add 子命令，用 update，且参数是“全量列表”，必须带上原有 IP
az network nat gateway show -g <RG> -n <NATGW> --query "publicIpAddresses[].id" -o tsv
az network nat gateway update -g <RG> -n <NATGW> --public-ip-addresses <OLD_PIP> <NEW_PIP>

az network nat gateway delete -g <RG> -n <NATGW>      # !! 需先从子网解绑
```
子网挂 NAT 网关后，出站优先走 NAT（优先于 LB 出站规则和实例级公网 IP 的出站）。

### Traffic Manager
```bash
az network traffic-manager profile list -o table
az network traffic-manager profile show -g <RG> -n <PROFILE>
az network traffic-manager endpoint list -g <RG> --profile-name <PROFILE> -o table
# routing-method: Geographic/MultiValue/Performance/Priority/Subnet/Weighted；unique-dns-name 全局唯一、小写
az network traffic-manager profile create -g <RG> -n <PROFILE> --routing-method Weighted --status Enabled --unique-dns-name <LABEL>
az network traffic-manager profile update -g <RG> -n <PROFILE> --status Disabled
```
Traffic Manager 是 DNS 级调度，切换受客户端 DNS TTL 影响，不是秒级。

## 5. 虚拟机与磁盘

```bash
az vm list --query "[?contains(name,'<KEYWORD>')].{VM:name,RG:resourceGroup}" -o table   # 按名字找 RG
az vm show -d -g <RG> -n <VM> --query "{Name:name,Size:hardwareProfile.vmSize,Loc:location,PrivateIP:privateIps,PublicIP:publicIps,Power:powerState}" -o table
az vm get-instance-view -g <RG> -n <VM> --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" -o tsv
```

电源操作：
```bash
az vm start      -g <RG> -n <VM>
az vm restart    -g <RG> -n <VM>
az vm stop       -g <RG> -n <VM>   # 只关机，计算资源仍计费
az vm deallocate -g <RG> -n <VM>   # 释放计算资源才停止计费；动态公网 IP 会变
az vm redeploy   -g <RG> -n <VM>   # !! 迁移到新宿主机（宿主机故障时用），临时盘数据丢失
```

谁动了这台 VM（活动日志）：
```bash
VM_ID=$(az vm show -g <RG> -n <VM> --query id -o tsv)
az monitor activity-log list --resource-id "$VM_ID" --offset 1d \
  --query "[].{Time:eventTimestamp,Op:operationName.value,Status:status.value,Caller:caller}" -o table
```

规格查询（`az vm list-sizes` 已废弃）：
```bash
az vm list-skus -l <LOCATION> --resource-type virtualMachines --size <SIZE_PREFIX> --query "[].{name:name,zones:locationInfo[0].zones,restr:restrictions[0].reasonCode}" -o table
```
restrictions 非空说明该区域/可用区对当前订阅不可用（容量或配额限制）。

磁盘：
```bash
az vm show -g <RG> -n <VM> --query "storageProfile.dataDisks[].{name:name,lun:lun,sizeGb:diskSizeGb,sku:managedDisk.storageAccountType}" -o table

# SKU：Standard_LRS(HDD) / StandardSSD_LRS / Premium_LRS / PremiumV2_LRS；zone 必须与 VM 一致
# --performance-plus 只能在创建时开启，且要求磁盘 ≥ 513 GiB
az disk create -g <RG> -n <DISK> -l <LOCATION> --zone <ZONE> --size-gb 1024 --sku Premium_LRS --performance-plus true
az vm disk attach -g <RG> --vm-name <VM> --name <DISK>                                  # 挂已有盘
az vm disk attach -g <RG> --vm-name <VM> --name <DISK> --new --size-gb <N> --sku <SKU>   # 新建并挂载

az disk list -g <RG> --query "[].{Name:name,Sku:sku.name,GB:diskSizeGb,Tier:tier,IOPS:diskIopsReadWrite,MBps:diskMBpsReadWrite,PerfPlus:creationData.performancePlus}" -o table
```
挂盘后还需在 OS 内分区、格式化、写 fstab（建议用 UUID + `nofail`）。

## 6. 存储账户 / Blob

```bash
az storage account list --query "[].{Name:name,RG:resourceGroup,Loc:location,Tier:accessTier,Kind:kind}" -o table
az storage account show -n <ACCOUNT> -g <RG> -o json
az storage account show -n <ACCOUNT> -g <RG> --query networkRuleSet.defaultAction   # Deny 时需在白名单网络/私有终结点内访问
az storage account network-rule list --account-name <ACCOUNT> -g <RG>
az storage account show -n <ACCOUNT> -g <RG> --query encryption
az storage account blob-service-properties show --account-name <ACCOUNT> -g <RG>    # 软删除、版本控制等
az storage account management-policy show --account-name <ACCOUNT> -g <RG> --query policy.rules   # 生命周期策略；无策略时报 not found
```

列容器/Blob：优先用 Entra 身份（`--auth-mode login`，需要 `Storage Blob Data Reader` 等数据面角色，仅有 Owner/Contributor 不够）。
```bash
az storage container list --account-name <ACCOUNT> --auth-mode login -o table
az storage blob list --account-name <ACCOUNT> -c <CONTAINER> --auth-mode login --prefix '<PREFIX>' --num-results 20 --show-next-marker -o table
# 翻页：把上次输出的 nextMarker 用单引号传入
az storage blob list --account-name <ACCOUNT> -c <CONTAINER> --auth-mode login --num-results 20 --marker '<MARKER>' --show-next-marker
```
- 没有数据面角色时才退回账户密钥：`az storage account keys list ...` 获取后用 `--account-key`。密钥等同全权限，不要写进脚本/历史（用 `read -s` 读入环境变量），用完即 `unset`；连接串（`show-connection-string`）同理。
- `az storage copy` 底层调用 azcopy，首次执行会自动下载。
