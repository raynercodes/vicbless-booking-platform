#!/usr/bin/env bash
# Prints the DNS records to add at Namecheap once a hosting stack has been deployed.
# Usage: bash infra/dns-records.sh dev|prod [domain]     (default domain: vicbless.com)
set -euo pipefail

ENVIRONMENT="${1:-}"
DOMAIN="${2:-vicbless.com}"
case "$ENVIRONMENT" in
  dev | prod) ;;
  *)
    echo "Usage: bash infra/dns-records.sh dev|prod [domain]"
    exit 1
    ;;
esac

STACK="vicbless-frontend-$ENVIRONMENT"
TARGET="$(aws cloudformation describe-stacks --stack-name "$STACK" --region us-east-1 \
  --query "Stacks[0].Outputs[?OutputKey=='DistributionDomain'].OutputValue" --output text)"
if [ -z "$TARGET" ] || [ "$TARGET" = "None" ]; then
  echo "Could not read DistributionDomain from $STACK. Has it been deployed yet?"
  exit 1
fi

echo "Add these at Namecheap (Domain List > Manage > Advanced DNS > Add New Record):"
echo ""
printf '  %-6s  %-6s  %s\n' "Type" "Host" "Value"
if [ "$ENVIRONMENT" = "dev" ]; then
  printf '  %-6s  %-6s  %s\n' "CNAME" "dev" "$TARGET"
  echo ""
  echo "Then open: https://dev.$DOMAIN/?key=<your DEV_PREVIEW_KEY>"
else
  printf '  %-6s  %-6s  %s\n' "ALIAS" "@" "$TARGET"
  printf '  %-6s  %-6s  %s\n' "CNAME" "www" "$TARGET"
  echo ""
  echo "(Skip the www line if PROD_INCLUDE_WWW is false. The bare domain needs ALIAS, not CNAME.)"
fi
echo ""
echo "First delete Namecheap's default parking records for the same host, if any, or they will clash."
