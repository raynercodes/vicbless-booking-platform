#!/usr/bin/env bash
# Vicbless: updates the AWS deploy role files (GitHub sign-in IDs, CloudFront permissions).
# Run from the REPO ROOT:  bash fix-vicbless-oidc-ids.sh
# Why: since July 15, 2026 GitHub puts numeric owner and repo IDs in the sign-in token of new repositories
# (repo:owner@ID/name@ID:...), so the deploy role's name-only trust no longer matches. This updates 3 files so the
# role trusts both forms and infra/bootstrap.sh looks the IDs up for you:
#   infra/github-oidc-role.yaml   infra/bootstrap.sh   infra/README.md
# It only replaces the exact versions I gave you before (FORCE=1 overwrites anyway). It runs no git or AWS commands.
set -euo pipefail
if [ ! -d .git ] || [ ! -d infra ]; then
  echo "Run this from the root of the vicbless-booking-platform repo (the folder with .git and infra/)."
  exit 1
fi
command -v python3 >/dev/null || { echo "python3 is needed to run this script."; exit 1; }
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cat > "$STAGE/infra__github-oidc-role.yaml" <<'VICBLESS_EOF'
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  One-time setup. The role GitHub Actions assumes (through OIDC, no stored keys) to deploy the Vicbless
  frontend hosting stacks, the backend stacks, and to upload the site. Also creates the GitHub sign-in
  provider when the account does not have one yet. Deploy once by hand, in us-east-1.

Parameters:
  GitHubRepo:
    Type: String
    Default: raynercodes/vicbless-booking-platform
    Description: owner/repo of the GitHub repository. Check it matches yours exactly.
  GitHubOwnerId:
    Type: String
    Default: ''
    AllowedPattern: '^[0-9]*$'
    Description: >-
      Numeric ID of the repository's owner (find it: gh api /users/<owner> --jq .id). GitHub puts it in the sign-in
      token of repositories created after July 15, 2026. Leave empty to accept only the old name-only format.
  GitHubRepoId:
    Type: String
    Default: ''
    AllowedPattern: '^[0-9]*$'
    Description: >-
      Numeric ID of the repository itself (find it: gh api /repos/<owner>/<repo> --jq .id). Used together with
      GitHubOwnerId.
  CreateOidcProvider:
    Type: String
    AllowedValues: ['true', 'false']
    Default: 'true'
    Description: >-
      true for a brand new AWS account: this stack creates GitHub's sign-in provider. false if the account already has
      one (an account can only have one), then the existing provider is used.
  OidcProviderArn:
    Type: String
    Default: ''
    Description: >-
      Only when CreateOidcProvider is false and the provider is not the standard one: its ARN. Leave empty to use the
      standard one (token.actions.githubusercontent.com).

Conditions:
  MakeProvider: !Equals [!Ref CreateOidcProvider, 'true']
  UseStandardProvider: !Equals [!Ref OidcProviderArn, '']
  HasIds: !And
    - !Not [!Equals [!Ref GitHubOwnerId, '']]
    - !Not [!Equals [!Ref GitHubRepoId, '']]

Resources:
  # GitHub's sign-in provider. Needed once per AWS account. AWS checks GitHub's certificate on its own, so no
  # thumbprint is needed.
  GitHubProvider:
    Type: AWS::IAM::OIDCProvider
    Condition: MakeProvider
    Properties:
      Url: https://token.actions.githubusercontent.com
      ClientIdList: [sts.amazonaws.com]

  DeployRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: vicbless-github-actions-role
      Description: Deploys the Vicbless frontend and backend stacks from GitHub Actions
      MaxSessionDuration: 3600
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Federated: !If
                - MakeProvider
                - !Ref GitHubProvider
                - !If
                  - UseStandardProvider
                  - !Sub arn:${AWS::Partition}:iam::${AWS::AccountId}:oidc-provider/token.actions.githubusercontent.com
                  - !Ref OidcProviderArn
            Action: sts:AssumeRoleWithWebIdentity
            Condition:
              StringEquals:
                token.actions.githubusercontent.com:aud: sts.amazonaws.com
              StringLike:
                token.actions.githubusercontent.com:sub:
                  # Old format (name only): repositories created before July 15, 2026.
                  - !Sub repo:${GitHubRepo}:ref:refs/heads/dev
                  - !Sub repo:${GitHubRepo}:ref:refs/heads/main
                  - !Sub repo:${GitHubRepo}:environment:production
                  # New format (names plus numeric IDs): repositories created after July 15, 2026.
                  - !If
                    - HasIds
                    - !Join
                      - ''
                      - - 'repo:'
                        - !Select [0, !Split ['/', !Ref GitHubRepo]]
                        - '@'
                        - !Ref GitHubOwnerId
                        - '/'
                        - !Select [1, !Split ['/', !Ref GitHubRepo]]
                        - '@'
                        - !Ref GitHubRepoId
                        - ':ref:refs/heads/dev'
                    - !Ref AWS::NoValue
                  - !If
                    - HasIds
                    - !Join
                      - ''
                      - - 'repo:'
                        - !Select [0, !Split ['/', !Ref GitHubRepo]]
                        - '@'
                        - !Ref GitHubOwnerId
                        - '/'
                        - !Select [1, !Split ['/', !Ref GitHubRepo]]
                        - '@'
                        - !Ref GitHubRepoId
                        - ':ref:refs/heads/main'
                    - !Ref AWS::NoValue
                  - !If
                    - HasIds
                    - !Join
                      - ''
                      - - 'repo:'
                        - !Select [0, !Split ['/', !Ref GitHubRepo]]
                        - '@'
                        - !Ref GitHubOwnerId
                        - '/'
                        - !Select [1, !Split ['/', !Ref GitHubRepo]]
                        - '@'
                        - !Ref GitHubRepoId
                        - ':environment:production'
                    - !Ref AWS::NoValue
      Policies:
        - PolicyName: vicbless-frontend-deploy
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Sid: HostingStacks
                Effect: Allow
                Action: cloudformation:*
                Resource: !Sub arn:${AWS::Partition}:cloudformation:${AWS::Region}:${AWS::AccountId}:stack/vicbless-frontend-*/*
              - Sid: ValidateTemplates
                Effect: Allow
                Action: cloudformation:ValidateTemplate
                Resource: '*'
              - Sid: SiteBuckets
                Effect: Allow
                Action: s3:*
                Resource:
                  - arn:aws:s3:::vicbless-frontend-*
                  - arn:aws:s3:::vicbless-frontend-*/*
              - Sid: CloudFront
                Effect: Allow
                Action:
                  - cloudfront:CreateDistribution
                  - cloudfront:UpdateDistribution
                  - cloudfront:DeleteDistribution
                  - cloudfront:GetDistribution
                  - cloudfront:GetDistributionConfig
                  - cloudfront:ListDistributions
                  - cloudfront:ListTagsForResource # CloudFormation reads a function's tags after creating it
                  - cloudfront:TagResource
                  - cloudfront:UntagResource
                  - cloudfront:CreateInvalidation
                  - cloudfront:GetInvalidation
                  - cloudfront:CreateOriginAccessControl
                  - cloudfront:UpdateOriginAccessControl
                  - cloudfront:DeleteOriginAccessControl
                  - cloudfront:GetOriginAccessControl
                  - cloudfront:ListOriginAccessControls
                  - cloudfront:CreateResponseHeadersPolicy
                  - cloudfront:UpdateResponseHeadersPolicy
                  - cloudfront:DeleteResponseHeadersPolicy
                  - cloudfront:GetResponseHeadersPolicy
                  - cloudfront:ListResponseHeadersPolicies
                  - cloudfront:GetCachePolicy
                  - cloudfront:GetCachePolicyConfig
                  - cloudfront:GetOriginRequestPolicy
                  - cloudfront:ListOriginRequestPolicies
                  - cloudfront:GetOriginAccessControlConfig
                  - cloudfront:GetResponseHeadersPolicyConfig
                  - cloudfront:ListCachePolicies
                  - cloudfront:CreateFunction
                  - cloudfront:UpdateFunction
                  - cloudfront:DeleteFunction
                  - cloudfront:DescribeFunction
                  - cloudfront:GetFunction
                  - cloudfront:PublishFunction
                  - cloudfront:ListFunctions
                Resource: '*' # CloudFront create and list actions do not support narrower resources
              - Sid: Certificates
                Effect: Allow
                Action:
                  - acm:RequestCertificate
                  - acm:DescribeCertificate
                  - acm:DeleteCertificate
                  - acm:ListCertificates
                  - acm:AddTagsToCertificate
                  - acm:ListTagsForCertificate
                Resource: '*'
              - Sid: DnsRecords
                Effect: Allow
                Action:
                  - route53:ChangeResourceRecordSets
                  - route53:ListResourceRecordSets
                  - route53:GetHostedZone
                Resource: !Sub arn:${AWS::Partition}:route53:::hostedzone/* # tighten to the vicbless.com zones if you like
              - Sid: DnsLookups
                Effect: Allow
                Action:
                  - route53:ListHostedZones
                  - route53:ListHostedZonesByName
                  - route53:GetChange
                Resource: '*'

        - PolicyName: vicbless-backend-deploy
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Sid: BackendStacks
                Effect: Allow
                Action: cloudformation:*
                Resource: !Sub arn:${AWS::Partition}:cloudformation:${AWS::Region}:${AWS::AccountId}:stack/vicbless-backend-*/*
              - Sid: SamTransform
                Effect: Allow
                Action: cloudformation:CreateChangeSet
                Resource: !Sub arn:${AWS::Partition}:cloudformation:${AWS::Region}:aws:transform/Serverless-2016-10-31
              - Sid: PackageUploads
                Effect: Allow
                Action:
                  - s3:GetObject
                  - s3:PutObject
                  - s3:GetBucketLocation
                  - s3:ListBucket
                Resource:
                  - arn:aws:s3:::vicbless-artifacts-*
                  - arn:aws:s3:::vicbless-artifacts-*/*
              - Sid: ApiFunction
                Effect: Allow
                Action: lambda:*
                Resource: !Sub arn:${AWS::Partition}:lambda:${AWS::Region}:${AWS::AccountId}:function:vicbless-api-*
              - Sid: HttpApi
                Effect: Allow
                Action: apigateway:*
                Resource:
                  - !Sub arn:${AWS::Partition}:apigateway:${AWS::Region}::/apis
                  - !Sub arn:${AWS::Partition}:apigateway:${AWS::Region}::/apis/*
                  - !Sub arn:${AWS::Partition}:apigateway:${AWS::Region}::/tags/*
              - Sid: Tables
                Effect: Allow
                Action: dynamodb:*
                Resource:
                  - !Sub arn:${AWS::Partition}:dynamodb:${AWS::Region}:${AWS::AccountId}:table/vicbless-*
                  - !Sub arn:${AWS::Partition}:dynamodb:${AWS::Region}:${AWS::AccountId}:table/vicbless-*/index/*
              - Sid: LogGroups
                Effect: Allow
                Action: logs:*
                Resource:
                  - !Sub arn:${AWS::Partition}:logs:${AWS::Region}:${AWS::AccountId}:log-group:/aws/lambda/vicbless-api-*
                  - !Sub arn:${AWS::Partition}:logs:${AWS::Region}:${AWS::AccountId}:log-group:/aws/lambda/vicbless-api-*:*
              - Sid: LogGroupLookups
                Effect: Allow
                Action: logs:DescribeLogGroups
                Resource: '*'
              # The function's own role is created by the backend stack. It is limited to roles named after the
              # stack, and the only AWS-managed policy it may attach is the basic logging one, so this role can't be
              # used to mint an administrator.
              - Sid: FunctionRoles
                Effect: Allow
                Action:
                  - iam:CreateRole
                  - iam:DeleteRole
                  - iam:GetRole
                  - iam:UpdateRole
                  - iam:UpdateAssumeRolePolicy
                  - iam:PassRole
                  - iam:TagRole
                  - iam:UntagRole
                  - iam:PutRolePolicy
                  - iam:GetRolePolicy
                  - iam:DeleteRolePolicy
                  - iam:ListRolePolicies
                  - iam:ListAttachedRolePolicies
                Resource: !Sub arn:${AWS::Partition}:iam::${AWS::AccountId}:role/vicbless-backend-*
              - Sid: FunctionRoleLogging
                Effect: Allow
                Action:
                  - iam:AttachRolePolicy
                  - iam:DetachRolePolicy
                Resource: !Sub arn:${AWS::Partition}:iam::${AWS::AccountId}:role/vicbless-backend-*
                Condition:
                  ArnEquals:
                    iam:PolicyARN: !Sub arn:${AWS::Partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

Outputs:
  RoleArn:
    Description: Put this in the GitHub repository variable AWS_DEPLOY_ROLE_ARN
    Value: !GetAtt DeployRole.Arn
VICBLESS_EOF
cat > "$STAGE/infra__bootstrap.sh" <<'VICBLESS_EOF'
#!/usr/bin/env bash
# One-time setup of a brand new AWS account for Vicbless. Run it once, signed in to VIC'S account:
#   bash infra/bootstrap.sh
# It creates (in us-east-1):
#   - the stack vicbless-github-oidc: GitHub's sign-in provider (if the account has none) and the deploy role
#   - the stack vicbless-artifacts: the two private buckets the backend deploy uploads its code to
# then prints the values to put in GitHub. Safe to run again: it changes nothing that is already up to date.
set -euo pipefail

cd "$(dirname "$0")/.."
REGION="us-east-1"
REPO="${1:-raynercodes/vicbless-booking-platform}" # owner/name of the GitHub repo. Must match exactly.

command -v aws > /dev/null || { echo "The AWS CLI is not installed. See infra/README.md, step 1."; exit 1; }

if ! WHO="$(aws sts get-caller-identity --query '[Account,Arn]' --output text 2> /dev/null)"; then
  echo "The AWS CLI is not signed in. For SSO run: aws sso login   (see infra/README.md, step 1)"
  exit 1
fi
ACCOUNT="$(cut -f1 <<< "$WHO")"
ARN="$(cut -f2 <<< "$WHO")"

echo "You are signed in to AWS account $ACCOUNT"
echo "as $ARN"
echo
echo "This has to be Vic's account, NOT one of yours (Debo's, fintech, personal)."
read -r -p "To continue, type the account number again: " CONFIRM
if [ "$CONFIRM" != "$ACCOUNT" ]; then
  echo "That did not match. Nothing was changed."
  exit 1
fi

# An account can only have ONE GitHub sign-in provider. If the stack already made it, keep making it
# (turning it off would delete it). If something else made it, use that one. If none, make it.
STACK_VALUE="$(aws cloudformation describe-stacks --stack-name vicbless-github-oidc --region "$REGION" \
  --query "Stacks[0].Parameters[?ParameterKey=='CreateOidcProvider'].ParameterValue | [0]" --output text 2> /dev/null || true)"
if [ "$STACK_VALUE" = "true" ] || [ "$STACK_VALUE" = "false" ]; then
  CREATE_PROVIDER="$STACK_VALUE"
else
  EXISTING="$(aws iam list-open-id-connect-providers \
    --query "OpenIDConnectProviderList[?contains(Arn, 'token.actions.githubusercontent.com')].Arn | [0]" --output text)"
  if [ -z "$EXISTING" ] || [ "$EXISTING" = "None" ]; then CREATE_PROVIDER="true"; else CREATE_PROVIDER="false"; fi
fi
echo
echo "GitHub sign-in provider: $([ "$CREATE_PROVIDER" = "true" ] && echo "will be created by this setup" || echo "already exists, will be used")"
echo "GitHub repository allowed to deploy: $REPO"

# GitHub puts the numeric IDs of the owner and the repo in the sign-in token of repositories created after
# July 15, 2026 (repo:owner@ID/name@ID:...). The deploy role has to trust that form, so look the IDs up.
# The repo is public, so this needs no login. If it cannot be reached, only the old name-only form is trusted
# and the first deploy from GitHub will say "Not authorized to perform sts:AssumeRoleWithWebIdentity".
OWNER_ID=""
REPO_ID=""
if command -v gh > /dev/null && gh auth status > /dev/null 2>&1; then
  OWNER_ID="$(gh api "/users/${REPO%%/*}" --jq .id 2> /dev/null || true)"
  REPO_ID="$(gh api "/repos/$REPO" --jq .id 2> /dev/null || true)"
fi
if [ -z "$OWNER_ID" ] || [ -z "$REPO_ID" ]; then
  INFO="$(curl -fsS "https://api.github.com/repos/$REPO" 2> /dev/null || true)"
  if [ -n "$INFO" ] && command -v python3 > /dev/null; then
    OWNER_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["owner"]["id"])' <<< "$INFO" 2> /dev/null || true)"
    REPO_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<< "$INFO" 2> /dev/null || true)"
  fi
fi
case "$OWNER_ID$REPO_ID" in
  '' | *[!0-9]*) OWNER_ID=""; REPO_ID="" ;;
esac
if [ -n "$OWNER_ID" ] && [ -n "$REPO_ID" ]; then
  echo "GitHub IDs found: owner $OWNER_ID, repo $REPO_ID (both sign-in formats will be trusted)"
else
  echo "WARNING: could not look up the GitHub owner and repo IDs. Only the old sign-in format will be trusted."
  echo "         If a GitHub deploy then says 'Not authorized to perform sts:AssumeRoleWithWebIdentity', re-run this"
  echo "         with the IDs:  GITHUB_OWNER_ID=<id> GITHUB_REPO_ID=<id> bash infra/bootstrap.sh"
  OWNER_ID="${GITHUB_OWNER_ID:-}"
  REPO_ID="${GITHUB_REPO_ID:-}"
fi
echo

# Only passed when known (an empty value is not worth risking on every version of the AWS CLI).
ID_PARAMS=()
if [ -n "$OWNER_ID" ] && [ -n "$REPO_ID" ]; then ID_PARAMS=("GitHubOwnerId=$OWNER_ID" "GitHubRepoId=$REPO_ID"); fi

echo "1/2 Deploy role (this takes a minute)..."
aws cloudformation deploy \
  --stack-name vicbless-github-oidc \
  --template-file infra/github-oidc-role.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION" \
  --parameter-overrides "GitHubRepo=$REPO" "CreateOidcProvider=$CREATE_PROVIDER" ${ID_PARAMS[@]+"${ID_PARAMS[@]}"} \
  --no-fail-on-empty-changeset

echo "2/2 Buckets for the backend's packaged code..."
aws cloudformation deploy \
  --stack-name vicbless-artifacts \
  --template-file infra/artifacts-buckets.yaml \
  --region "$REGION" \
  --no-fail-on-empty-changeset

ROLE_ARN="$(aws cloudformation describe-stacks --stack-name vicbless-github-oidc --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='RoleArn'].OutputValue" --output text)"

echo
echo "Done. In GitHub (repo Settings > Secrets and variables > Actions > Variables) add:"
echo
echo "  AWS_DEPLOY_ROLE_ARN = $ROLE_ARN"
echo
echo "or, if you use the GitHub CLI (gh auth login first):"
echo "  gh variable set AWS_DEPLOY_ROLE_ARN --repo $REPO --body '$ROLE_ARN'"
echo
echo "Next: infra/README.md, step 4 (the HTTPS certificate)."
VICBLESS_EOF
cat > "$STAGE/infra__README.md" <<'VICBLESS_EOF'
# Putting Vicbless on AWS and vicbless.com

This is the whole runbook, in order. Everything lives in **us-east-1** in **Vic's own AWS account**.

What gets built (dev and prod are separate copies):

- **Frontend**: a private S3 bucket behind CloudFront (HTTPS only), on `vicbless.com`, `www.vicbless.com` and `dev.vicbless.com`
- **Backend**: API Gateway + Lambda + one DynamoDB table
- **One address for both**: CloudFront sends `/api/*` to the backend, so the site and the API share one domain
  (no cross-site rules to get wrong)
- dev is private: a no-index header and a preview link, so only people you send the link to can see it

DNS stays at **Namecheap** (free). A few records are added by hand, once. Helper scripts print exactly what to enter.

## The repo is public

That is fine, and these are the reasons it stays safe:

- **No secrets are in the repo.** Vic's password hash, the session secret and the email key live in AWS (Parameter Store)
  and are typed in by hand in step 7. The AWS account number is not in any file either.
- **GitHub signs in to AWS with short-lived tokens (OIDC), not stored keys.** The deploy role only trusts this repo's
  `dev` and `main` branches and the `production` environment. A pull request from a stranger's fork cannot deploy.
- Do these three things in GitHub (Settings):
  1. **Actions > General > Fork pull request workflows**: require approval for all outside collaborators.
  2. **Branches**: protect `main` (require a pull request, no force pushes). Only people who can push to `dev` or `main`
     can deploy, so keep the collaborator list to you.
  3. **Environments > production**: add yourself as a **required reviewer** (step 5). That is the approval before anything
     reaches the real site.

## Step 1. Safe access to Vic's AWS account (about 20 minutes)

The account was just created, so it only has its **root** login. Don't deploy with root.

1. Sign in as root (Vic's email) and turn on **MFA** for it (Account name menu > Security credentials). Then keep that login
   in a drawer: it is only for emergencies.
2. Add a **billing alert** so a mistake can never surprise anyone: Billing > Budgets > Create budget, a monthly cost
   budget of about $10 that emails Vic and you. This site should cost a few dollars a month at most.
3. Give yourself an admin login that is not root. The better way is **IAM Identity Center** (free): enable it, create a
   user for yourself, create a permission set with `AdministratorAccess`, assign it to the account, then on your computer:

   ```bash
   aws configure sso      # follow the prompts, use region us-east-1, give the profile a name like vicbless
   aws sso login --profile vicbless
   export AWS_PROFILE=vicbless      # so every command below uses Vic's account
   ```

   The simpler fallback is an IAM user with MFA and access keys. It works but long-lived keys are riskier.
   (Menu names are as I remember them, AWS moves things around.)
4. Install the AWS CLI v2 if you don't have it (`aws --version`).
5. **Brand new accounts sometimes need a check before CloudFront works.** If a later step says *"Your account must be
   verified before you can add new CloudFront resources"*, open an AWS Support case (Support Center > Create case >
   Account and billing) asking for verification. It is usually sorted within a day, so it is worth knowing about now.
   Lambda can also start with a low concurrency limit on new accounts. That is fine for this site.

## Step 2. Create the deploy role and buckets (one command)

From the repo root, with `AWS_PROFILE` pointing at Vic's account:

```bash
bash infra/bootstrap.sh
```

It shows the account number and **makes you type it again**, so you cannot deploy to the wrong account by accident.
Then it creates the GitHub sign-in provider (new accounts have none), the deploy role, and the two buckets the backend
uploads its code to. It prints the role to copy into GitHub.

**Why it looks up two numbers.** Since July 15, 2026, GitHub puts the numeric IDs of the owner and the repository in the
sign-in token of every repository created after that date (`repo:owner@ID/name@ID:ref:refs/heads/dev` instead of
`repo:owner/name:ref:refs/heads/dev`). The bootstrap fetches both IDs from GitHub (the repo is public, no login needed)
and makes the role trust both forms. If GitHub Actions ever says `Not authorized to perform sts:AssumeRoleWithWebIdentity`,
the role was deployed without the IDs: run `GITHUB_OWNER_ID=<id> GITHUB_REPO_ID=<id> bash infra/bootstrap.sh`
(`gh api /users/<owner> --jq .id` and `gh api /repos/<owner>/<repo> --jq .id` print them). Renaming or transferring the
repo changes the form again, so run the bootstrap again after either.

## Step 3. GitHub variables and secrets

Settings > Secrets and variables > Actions.

| Name | Kind | Value |
|---|---|---|
| `AWS_DEPLOY_ROLE_ARN` | variable | printed by step 2 |
| `DEV_PREVIEW_KEY` | **secret** | a long random string. Make one with `openssl rand -hex 16` |
| `DEV_DOMAIN` | variable | `dev.vicbless.com` (leave empty at first to test on the plain cloudfront.net address) |
| `DEV_CERTIFICATE_ARN` | variable | from step 4 (empty until then) |
| `PROD_DOMAIN` | variable | `vicbless.com` |
| `PROD_INCLUDE_WWW` | variable | `true` |
| `PROD_CERTIFICATE_ARN` | variable | the same certificate as dev, from step 4 |
| `DEV_HOSTED_ZONE_ID`, `PROD_HOSTED_ZONE_ID` | variable | leave empty (only for Route 53) |

You do **not** need the CORS variables: the site and the API share one address, and prod already defaults to
`https://vicbless.com,https://www.vicbless.com`.

## Step 4. HTTPS certificate

```bash
bash infra/request-certificate.sh
```

It prints the `CertificateArn` and 3 CNAME records. At Namecheap: Domain List > Manage > **Advanced DNS** > Add New Record.
Namecheap wants only the part before the domain in the Host box, and the script prints it that way.

Wait for `ISSUED` (usually a few minutes after the records are saved):

```bash
aws acm describe-certificate --region us-east-1 --certificate-arn <the CertificateArn> --query Certificate.Status --output text
```

Put the ARN into `DEV_CERTIFICATE_ARN` and `PROD_CERTIFICATE_ARN`. **Keep those 3 records at Namecheap forever**: AWS renews the
certificate by itself, but only while they exist.

## Step 5. The approval gate for prod

GitHub: Settings > Environments > New environment named exactly `production`, add yourself as a required reviewer.

## Step 6. Turn the workflows back on

```bash
bash pause-vicbless-workflows.sh resume
```

## Step 7. Vic's password and settings (before the first backend deploy is used)

The backend reads its secrets from AWS. Run, with `AWS_PROFILE` set to Vic's account:

```bash
python backend/scripts/hash_password.py --env dev
```

It asks for Vic's dashboard password (**Vic should type it himself**, it is hidden), makes the other two secrets, and prints
`aws ssm put-parameter` commands. Run those, then the three it lists for `owner-email`, `email-from` and `resend-api-key`.
Clear your terminal history afterwards. Repeat with `--env prod` later, with its own password.

## Step 8. Deploy dev

Push the `dev` branch. **Two workflows start**: Deploy backend and Deploy frontend. The frontend one may finish first and
find no backend yet, which is fine, it just leaves `/api` unconnected. When Deploy backend is green:

1. GitHub > Actions > **Deploy frontend** > Run workflow > dev. It now finds the backend and connects `/api/*`.
2. Point the name at it:

   ```bash
   bash infra/dns-records.sh dev
   ```

   Add the one record it prints (a CNAME for `dev`).
3. Open `https://dev.vicbless.com/?key=<your DEV_PREVIEW_KEY>` once on each device. Anyone without the link sees
   "This site is not public yet."
4. Check the backend answers: `https://dev.vicbless.com/api/health` should show `status`, `environment` and a version.

The first backend deploy may stop with an "AccessDenied" for one specific action. The role's permissions were written
without being able to try them against a real account, so if it happens: send me the exact error line, it is a one-line fix.

## Step 9. Deploy prod when dev is happy

1. Deploy the **prod backend** first: Actions > Deploy backend > Run workflow > prod (from `main`). Approve it.
2. Run `python backend/scripts/hash_password.py --env prod` (step 7).
3. Actions > **Deploy frontend** > Run workflow > prod (from `main`). It prints the plan, waits for approval, applies it.
4. `bash infra/dns-records.sh prod` and add the two records it prints (an **ALIAS** for the bare domain, a CNAME for `www`).

## Email (can wait until dev works)

Until `vicbless.com` is verified in Resend, Resend only sends from `onboarding@resend.dev` and only **to the email the Resend
account was made with**. So for testing, set `owner-email` to that address. To email real customers: add the domain in Resend,
add the DNS records it lists at Namecheap, wait for "Verified", then change `email-from` to something like
`Vicbless <bookings@vicbless.com>`. Later, when AWS SES gets production access, swap it in (see `backend/README.md`).
A failed email never stops a booking.

## Two things to check at Namecheap

- **Is there an ALIAS record type?** In Advanced DNS > Add New Record. As far as I know Namecheap has one, and a bare domain
  needs it to point at CloudFront. If it is missing, tell me before going live: Namecheap's "URL Redirect" only works over plain
  HTTP, so `https://vicbless.com` would show a certificate error. That is the case where Route 53 (about $6 a year) is worth it.
- **Clear the default parking records** before adding yours. A new domain usually has a `www` CNAME pointing at Namecheap's
  parking page and a URL Redirect record. A leftover one clashes with yours.

## Good to know

- Cache rules: files in `assets/` are cached for a year, `media/` for a day, `index.html` never. Each deploy refreshes `/index.html` and `/media/*`.
- The S3 buckets, the DynamoDB tables and the log groups are **kept** if you ever delete their stacks, so data is never lost by accident.
- The preview key sits inside the CloudFront function's code, which anyone with access to the AWS account can read. It is a privacy
  gate for a test site, not a security boundary. Prod has no gate.
- The sign-in lockout is a coarse brake behind CloudFront (it sees CloudFront's address, not the visitor's), so the login
  route is also throttled hard at API Gateway.
- A Content-Security-Policy header is not set yet. A good thing to add before launch.
VICBLESS_EOF
export STAGE
python3 - <<'PY'
import hashlib, os, stat, sys
from pathlib import Path
stage = Path(os.environ["STAGE"]); force = os.environ.get("FORCE") == "1"
PREV = {'infra/github-oidc-role.yaml': ['7a22eb1029f06f79ea88d3aeab4589d40be0757726eaee6afc72238419c9c5e4', '18116f7c185f6cb69b2287f3e6a10a976e987eef9ec62c9df5bfd492da6cc79f'], 'infra/bootstrap.sh': ['84f51d3d0043942dc7329ba7b0d9c7aa0e8153fd502b841d1daaaf1480bc484a', '5a4e50b90b5c1f9aa19e780ac085d91ae3217c24438c8a9683ef452b0bdf5eba'], 'infra/README.md': ['f9b7e10005cf8b9205d7b24918d976eae3c626e77bda0a2bf69c1769cea25435', '061fdfc643c07121a9641355036e39c61b91d216003c3bc37078fc13c4d5b9eb']}
sha = lambda s: hashlib.sha256(s.encode()).hexdigest()
plan, problems = [], []
for rel, old in PREV.items():
    new_text = (stage / rel.replace("/", "__")).read_text()
    path = Path(rel)
    if path.exists():
        cur = sha(path.read_text())
        if cur == sha(new_text):
            continue
        if cur not in old and not force:
            problems.append(rel); continue
    elif not force:
        problems.append(rel + " (missing: run add-vicbless-aws-setup.sh first)"); continue
    plan.append((path, new_text))
if problems:
    print("Stopped. These files are not the versions this script expects (did you edit them?):")
    for p in problems: print("  -", p)
    print("Nothing was changed. Tell me what differs, or run with FORCE=1 to overwrite them.")
    sys.exit(1)
for path, text in plan:
    path.parent.mkdir(parents=True, exist_ok=True); path.write_text(text)
    if path.suffix == ".sh": path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
print("Wrote:" if plan else "Already up to date. Nothing to change.")
for path, _ in plan: print("  -", path)
PY
echo
echo "Next, with Vic's profile:"
echo "  export AWS_PROFILE=vicbless"
echo "  bash infra/bootstrap.sh      (retype the account number; it should print 'GitHub IDs found')"
echo "Then re-run the failed GitHub workflow."
