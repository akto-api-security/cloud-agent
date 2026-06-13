# Bootstrap AWS from scratch

## What gets created

| Resource | Name |
|----------|------|
| IAM managed policy | `CloudAgentBedrockPolicy` |
| IAM user | `cloud-agent-staging` |
| IAM role | `cloud-agent-bedrock` |
| Access key | for `cloud-agent-staging` |
| AWS CLI profile (keys) | `cloud-agent-staging` |
| AWS CLI profile (role) | `cloud-agent-bedrock` |
| `.env` | for cloud-agent |

## Steps (copy-paste)

### 1. Install AWS CLI + login with admin

```bash
# macOS
brew install awscli

# Configure with your admin/root account keys
aws configure
# Access Key ID:     <your admin key>
# Secret Access Key: <your admin secret>
# Region:            <your region, e.g. us-east-1>
# Output:            json
```

Verify:

```bash
aws sts get-caller-identity
```

### 2. Python env for cloud-agent

```bash
cd cloud-agent
python3 -m venv .venv
source .venv/bin/activate
pip3 install -r requirements.txt
```

### 3. Run bootstrap (creates everything)

```bash
chmod +x scripts/bootstrap-account.sh
./scripts/bootstrap-account.sh
```

The script will:
1. Create IAM policy, user, role
2. Create access key (save it — shown once)
3. Configure `~/.aws/credentials` and `~/.aws/config`
4. Pause for **Bedrock model access** in console
5. Test Bedrock Converse (SigV4)
6. Write `.env`

### 4. Bedrock model access

AWS **retired** the manual model access page — models are enabled automatically.
Access is controlled via IAM. If Converse fails with `AccessDenied`:

```bash
./scripts/fix-bedrock-policy.sh
```

### 5. Use the agent

```bash
export AWS_PROFILE=cloud-agent-bedrock
python3 debug_bedrock.py    # SigV4 wire headers
python3 agent.py              # full agent
./scripts/setup-aws.sh test-proxy   # via Akto proxy
```

## Manual fallback (if script fails)

```bash
# Create policy
aws iam create-policy --policy-name CloudAgentBedrockPolicy \
  --policy-document file://scripts/policies/bedrock-policy.json

# Create user + role — see bootstrap-account.sh for JSON documents
```

## Tear down (when done testing)

Replace `<ACCOUNT_ID>` with your account ID from `aws sts get-caller-identity`.

```bash
aws iam detach-role-policy --role-name cloud-agent-bedrock \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/CloudAgentBedrockPolicy
aws iam delete-role --role-name cloud-agent-bedrock
aws iam delete-user-policy --user-name cloud-agent-staging --policy-name cloud-agent-bedrock-assume
aws iam delete-access-key --user-name cloud-agent-staging --access-key-id <KEY_ID>
aws iam delete-user --user-name cloud-agent-staging
aws iam delete-policy --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/CloudAgentBedrockPolicy
```
