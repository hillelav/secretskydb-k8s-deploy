# Install SecretSkyDB from Cloud Shell

<walkthrough-tutorial-duration duration="20"></walkthrough-tutorial-duration>

This walkthrough runs entirely in Cloud Shell, which already has `gcloud`, `kubectl`,
`terraform` and `helm`. It prepares the share stores and deploys the SecretSkyDB proxy
into a GKE cluster in your project.

Click **Start**.

## Select your project

<walkthrough-project-setup></walkthrough-project-setup>

The project needs billing enabled and a GKE cluster. If you do not have a cluster yet,
create a small one (a few minutes):

```sh
gcloud container clusters create-auto secretskydb-eval --region us-central1 --project {{project-id}}
```

## Connect to the cluster

```sh
gcloud container clusters get-credentials secretskydb-eval --region us-central1 --project {{project-id}}
kubectl get nodes
```

Replace the cluster name and region if you use an existing cluster.

## Choose a path

**A. Marketplace, metered to your invoice (production).** Prepare the share stores,
then click Deploy on the Marketplace listing:

```sh
PROJECT_ID={{project-id}} NETWORK=projects/{{project-id}}/global/networks/default MANAGE_PSA=true ./scripts/prepare-shares.sh
```

When it finishes it prints the values for the deploy form. Open
<walkthrough-menu-navigation sectionId="MARKETPLACE_SECTION">Marketplace</walkthrough-menu-navigation>,
search **SecretSkyDB**, click **Configure**, enter those values, leave the licence key
empty, and click **Deploy**.

**B. Quick evaluation, no AlloyDB (three stand-in shares inside the cluster).**
Everything in one command, about three minutes:

```sh
PROJECT_ID={{project-id}} SHARES=test ./scripts/install-secretskydb.sh
```

## Test it

Connect as to any PostgreSQL server:

```sh
kubectl -n secretskydb port-forward svc/secretskydb 55432:55432 >/dev/null 2>&1 &
PW=$(kubectl -n secretskydb get secret secretskydb-alloydb-shares -o jsonpath='{.data.proxy}' | base64 -d)
PGPASSWORD=$PW psql "host=127.0.0.1 port=55432 user=ssdb dbname=ssdb"
```

In `psql`, a table with a protected column (the `\;` sends the CREATE and its policy
to the proxy together, so the column is Secret from its first row):

```sql
CREATE TABLE emp (id int, name text, salary numeric) \; COMMENT ON COLUMN emp.salary IS 'SSDB: secret';
INSERT INTO emp VALUES (1,'dana',12000),(2,'omer',15000);
SELECT * FROM emp;
SELECT sum(salary) FROM emp;
```

The salary comes back whole through the proxy; the sum is computed on the shares. Licence
and share status:

```sh
kubectl -n secretskydb port-forward pod/secretskydb-0 55433:55433 >/dev/null 2>&1 &
curl -s http://127.0.0.1:55433/statusz | python3 -m json.tool
```

## Remove it

```sh
kubectl delete application/secretskydb -n secretskydb
```

For path A, `./scripts/uninstall-secretskydb.sh` with the same variables also destroys the
AlloyDB shares and all data on them. Delete the evaluation cluster when you are done:

```sh
gcloud container clusters delete secretskydb-eval --region us-central1 --project {{project-id}}
```

<walkthrough-conclusion-trophy></walkthrough-conclusion-trophy>

Questions: support@secretskydb.com
