# AlertmanagerNotificationsFailing

**Severity:** critical · **Fires when:**
`increase(alertmanager_notifications_failed_total[10m]) > 0` for 5 minutes

This is the alert about the alerts. Everything else in this repository assumes
that when something breaks, someone is told. This is the alert that fires when
that assumption is false.

Treat it as critical even though nothing user-facing is broken. While it is
firing, every other alert in the system is being raised into a void, and the
inbox looks exactly the same as a healthy cluster: empty.

## The thing that does NOT set this off

**An unconfirmed SNS subscription.** If the email subscription is still
`PendingConfirmation`, Alertmanager's publish to SNS **succeeds** — the topic
accepts the message and then delivers it to nobody. `notifications_failed_total`
never increments and this alert stays quiet, which is the worst failure mode in
the whole monitoring plane: alerting is broken and the alert-about-alerting says
everything is fine.

So check that first, because it is invisible from here:

```bash
aws sns list-subscriptions-by-topic \
  --topic-arn "$(cd terraform && terraform output -raw sns_topic_arn)" \
  --query 'Subscriptions[].{Endpoint:Endpoint,Arn:SubscriptionArn}' --output table
```

`PendingConfirmation` in the Arn column means click the link in the confirmation
email. Nothing in the cluster will ever tell you this.

## First three commands

```bash
kubectl logs -n observability -l app.kubernetes.io/name=alertmanager \
  -c alertmanager --tail=100 | grep -i "error\|sns\|notify"
kubectl get sa alertmanager -n observability -o yaml | grep role-arn
./scripts/port-forward-monitoring.sh   # then http://localhost:9093/#/status
```

## Work through it in this order

1. **Read the actual error.** Alertmanager says why it failed, and the reason
   picks the branch:

   - `AccessDenied` → IRSA, step 2
   - `NotFound` / `InvalidParameter` → the topic ARN, step 3
   - `no credentials` → the ServiceAccount annotation is missing entirely

2. **IRSA.** The trust policy in `terraform/modules/irsa` names the
   ServiceAccount `alertmanager` in namespace `observability` **exactly**. The
   chart values pin that name rather than deriving it from the release name, and
   the comment there explains why: a renamed release would make the pod start
   normally and every publish fail.

   ```bash
   kubectl get sa alertmanager -n observability \
     -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}{"\n"}'
   cd terraform && terraform output -raw alertmanager_role_arn
   ```

   These two must match. If the annotation is empty, the chart values lost the
   `PLACEHOLDER_ALERTMANAGER_ROLE_ARN` substitution — re-run
   `./scripts/install-observability.sh`.

3. **The topic.** A destroyed and recreated stack produces a new topic ARN, and
   an Alertmanager still holding the old one publishes to something that no
   longer exists:

   ```bash
   curl -s localhost:9093/api/v2/status \
     | python3 -c 'import json,sys; print(json.load(sys.stdin)["config"]["original"])' \
     | grep -A3 sns_configs
   cd terraform && terraform output -raw sns_topic_arn
   ```

   Reading it from the API rather than from the values file matters: it shows
   what Alertmanager is **running**, not what someone intended it to run.

4. **Egress.** Alertmanager reaches SNS over HTTPS on 443. If its NetworkPolicy
   lost that rule, publishes time out rather than being refused:

   ```bash
   kubectl get netpol -n observability alertmanager -o yaml | grep -A10 egress
   ```

## Confirming the fix

Force a real notification rather than trusting the absence of errors:

```bash
kubectl scale deploy backend -n devops-app --replicas=0
# wait ~5 minutes for ReplicasMismatch, check your inbox, then:
kubectl scale deploy backend -n devops-app --replicas=2
```

An end-to-end delivery is the only proof that counts here. `Watchdog` firing
tells you Prometheus is evaluating rules; it does **not** tell you Alertmanager
can deliver, because `Watchdog` is routed to the null receiver on purpose.

## Related

- [PrometheusTargetDown](PrometheusTargetDown.md) — the other way alerting goes
  quiet: no metrics rather than no delivery.
- [MonitoringGateFailed](MonitoringGateFailed.md) — when CD's gate cannot get
  answers out of Prometheus.
