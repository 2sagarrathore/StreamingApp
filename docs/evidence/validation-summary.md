# Validation Summary

Automated run by `run-project.sh`.

| | |
|---|---|
| Started | 2026-08-15T11:31:52Z |
| Finished | 2026-08-15T11:41:32Z |
| Region | ap-south-1 |
| Cluster | streamingapp-eks |
| Namespace | streamingapp |
| Application URL | k8s-streamingapp-ac32464491-1158707937.ap-south-1.elb.amazonaws.com |

## Cluster state at the end of the run

```
NAME                                          READY   STATUS    RESTARTS   AGE
pod/streamingapp-admin-56595b7c75-vl8h2       1/1     Running   0          9m26s
pod/streamingapp-auth-5bc74bb87f-chmvp        1/1     Running   0          6m
pod/streamingapp-auth-5bc74bb87f-l8qtl        1/1     Running   0          9m11s
pod/streamingapp-auth-5bc74bb87f-nrdpn        1/1     Running   0          4m40s
pod/streamingapp-auth-5bc74bb87f-nswrg        1/1     Running   0          4m40s
pod/streamingapp-chat-777dcc6f6b-m4gm8        1/1     Running   0          9m26s
pod/streamingapp-frontend-76dcd48797-sb6s7    1/1     Running   0          9m11s
pod/streamingapp-frontend-76dcd48797-xv92g    1/1     Running   0          9m26s
pod/streamingapp-mongodb-0                    1/1     Running   0          9m26s
pod/streamingapp-streaming-67f856cc87-5srtf   1/1     Running   0          9m11s
pod/streamingapp-streaming-67f856cc87-gj7vg   1/1     Running   0          9m26s

NAME                             TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)     AGE
service/streamingapp-admin       ClusterIP   172.20.149.102   <none>        3003/TCP    9m26s
service/streamingapp-auth        ClusterIP   172.20.88.41     <none>        3001/TCP    9m26s
service/streamingapp-chat        ClusterIP   172.20.62.204    <none>        3004/TCP    9m26s
service/streamingapp-frontend    ClusterIP   172.20.225.33    <none>        80/TCP      9m26s
service/streamingapp-mongodb     ClusterIP   None             <none>        27017/TCP   9m26s
service/streamingapp-streaming   ClusterIP   172.20.13.43     <none>        3002/TCP    9m26s

NAME                                     READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/streamingapp-admin       1/1     1            1           9m27s
deployment.apps/streamingapp-auth        4/4     4            4           9m27s
deployment.apps/streamingapp-chat        1/1     1            1           9m27s
deployment.apps/streamingapp-frontend    2/2     2            2           9m27s
deployment.apps/streamingapp-streaming   2/2     2            2           9m27s

NAME                                                DESIRED   CURRENT   READY   AGE
replicaset.apps/streamingapp-admin-56595b7c75       1         1         1       9m27s
replicaset.apps/streamingapp-auth-5bc74bb87f        4         4         4       9m27s
replicaset.apps/streamingapp-chat-777dcc6f6b        1         1         1       9m27s
replicaset.apps/streamingapp-frontend-76dcd48797    2         2         2       9m27s
replicaset.apps/streamingapp-streaming-67f856cc87   2         2         2       9m27s

NAME                                    READY   AGE
statefulset.apps/streamingapp-mongodb   1/1     9m27s

NAME                                                         REFERENCE                           TARGETS                         MINPODS   MAXPODS   REPLICAS   AGE
horizontalpodautoscaler.autoscaling/streamingapp-auth        Deployment/streamingapp-auth        cpu: 58%/70%, memory: 55%/80%   2         8         4          9m27s
horizontalpodautoscaler.autoscaling/streamingapp-frontend    Deployment/streamingapp-frontend    cpu: 2%/70%, memory: 4%/80%     2         6         2          9m27s
horizontalpodautoscaler.autoscaling/streamingapp-streaming   Deployment/streamingapp-streaming   cpu: 1%/65%, memory: 19%/80%    2         10        2          9m27s
```

## Endpoint checks

```
# Endpoint checks against http://k8s-streamingapp-ac32464491-1158707937.ap-south-1.elb.amazonaws.com
# 2026-08-15T11:35:21Z

/                                        HTTP 200
/healthz                                 HTTP 200
/svc/auth/health                         HTTP 200
/svc/streaming/api/health                HTTP 200
/svc/admin/api/health                    HTTP 200
/svc/chat/api/chat                       HTTP 404

# Response bodies
--- /healthz
{"status":"ok","component":"frontend"}
--- /svc/auth/health
{"status":"OK"}
--- /svc/streaming/api/health
{"msg":"OK"}
--- /svc/admin/api/health
{"success":true,"service":"admin","status":"ok"}
```

## Autoscaling

```
# HPA before load
NAME                     REFERENCE                           TARGETS                        MINPODS   MAXPODS   REPLICAS   AGE
streamingapp-auth        Deployment/streamingapp-auth        cpu: 1%/70%, memory: 30%/80%   2         8         2          3m58s
streamingapp-frontend    Deployment/streamingapp-frontend    cpu: 2%/70%, memory: 4%/80%    2         6         2          3m58s
streamingapp-streaming   Deployment/streamingapp-streaming   cpu: 0%/65%, memory: 19%/80%   2         10        2          3m58s

# HPA after 1 minute(s) of load
NAME                     REFERENCE                           TARGETS                          MINPODS   MAXPODS   REPLICAS   AGE
streamingapp-auth        Deployment/streamingapp-auth        cpu: 142%/70%, memory: 54%/80%   2         8         2          5m
streamingapp-frontend    Deployment/streamingapp-frontend    cpu: 2%/70%, memory: 4%/80%      2         6         2          5m
streamingapp-streaming   Deployment/streamingapp-streaming   cpu: 0%/65%, memory: 19%/80%     2         10        2          5m
auth pod count: 4

# HPA after 2 minute(s) of load
NAME                     REFERENCE                           TARGETS                         MINPODS   MAXPODS   REPLICAS   AGE
streamingapp-auth        Deployment/streamingapp-auth        cpu: 76%/70%, memory: 54%/80%   2         8         4          6m2s
streamingapp-frontend    Deployment/streamingapp-frontend    cpu: 2%/70%, memory: 4%/80%     2         6         2          6m2s
streamingapp-streaming   Deployment/streamingapp-streaming   cpu: 0%/65%, memory: 19%/80%    2         10        2          6m2s
auth pod count: 4

# HPA after 3 minute(s) of load
NAME                     REFERENCE                           TARGETS                         MINPODS   MAXPODS   REPLICAS   AGE
streamingapp-auth        Deployment/streamingapp-auth        cpu: 67%/70%, memory: 54%/80%   2         8         4          7m3s
streamingapp-frontend    Deployment/streamingapp-frontend    cpu: 2%/70%, memory: 4%/80%     2         6         2          7m3s
streamingapp-streaming   Deployment/streamingapp-streaming   cpu: 0%/65%, memory: 19%/80%    2         10        2          7m3s
auth pod count: 4

# HPA after 4 minute(s) of load
NAME                     REFERENCE                           TARGETS                         MINPODS   MAXPODS   REPLICAS   AGE
streamingapp-auth        Deployment/streamingapp-auth        cpu: 63%/70%, memory: 55%/80%   2         8         4          8m5s
streamingapp-frontend    Deployment/streamingapp-frontend    cpu: 2%/70%, memory: 4%/80%     2         6         2          8m5s
streamingapp-streaming   Deployment/streamingapp-streaming   cpu: 0%/65%, memory: 19%/80%    2         10        2          8m5s
auth pod count: 4

# Load generator stopped. The HPA scales back down after its
# 300-second stabilisation window.
```

## Self-healing

```
# Before
NAME                                 READY   STATUS    RESTARTS   AGE
streamingapp-auth-5bc74bb87f-g7tjt   1/1     Running   0          3m24s
streamingapp-auth-5bc74bb87f-l8qtl   1/1     Running   0          3m9s

$ kubectl delete pod streamingapp-auth-5bc74bb87f-g7tjt -n streamingapp
pod "streamingapp-auth-5bc74bb87f-g7tjt" deleted from streamingapp namespace

# After (Kubernetes scheduled a replacement)
NAME                                 READY   STATUS    RESTARTS   AGE
streamingapp-auth-5bc74bb87f-chmvp   1/1     Running   0          32s
streamingapp-auth-5bc74bb87f-l8qtl   1/1     Running   0          3m43s
```

## Files in this directory

```
00-aws-identity.txt
00-aws-version.txt
01-ecr-repositories.txt
02-eks-cluster.txt
02-nodes.txt
03-kube-system.txt
03-storageclass.txt
04-deploy.log
04-helm-history.txt
04-helm-release.txt
04-hpa.txt
04-ingress.txt
04-pvc.txt
04-workloads.txt
05-chatops.log
06-alarms.txt
06-log-groups.txt
06-monitoring.log
07-endpoint-checks.txt
07-helm-smoke-test.txt
08-self-healing.txt
09-hpa-scaling.txt
10-events.txt
10-top-nodes.txt
10-top-pods.txt
README.md
app-url.txt
validation-summary.md
```
