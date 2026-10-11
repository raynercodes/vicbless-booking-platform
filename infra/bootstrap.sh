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
