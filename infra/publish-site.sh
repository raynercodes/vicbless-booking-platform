#!/usr/bin/env bash
# Uploads the built site to the hosting stack's bucket and refreshes CloudFront.
# Usage: bash infra/publish-site.sh <stack-name> <built-site-folder>
set -euo pipefail

STACK="${1:?Usage: publish-site.sh <stack-name> <built-site-folder>}"
SITE="${2:?Usage: publish-site.sh <stack-name> <built-site-folder>}"

if [ ! -f "$SITE/index.html" ]; then
  echo "No index.html in $SITE. Build the site first."
  exit 1
fi

output() {
  aws cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

BUCKET="$(output BucketName)"
DISTRIBUTION_ID="$(output DistributionId)"
if [ -z "$BUCKET" ] || [ "$BUCKET" = "None" ] || [ -z "$DISTRIBUTION_ID" ] || [ "$DISTRIBUTION_ID" = "None" ]; then
  echo "Could not read BucketName and DistributionId from stack $STACK."
  exit 1
fi

# 1. Hashed files first. Their names change when their content does, so they can be cached for a year.
#    Old ones are left in place on purpose, so a visitor holding an older page still finds its files.
if [ -d "$SITE/assets" ]; then
  aws s3 sync "$SITE/assets" "s3://$BUCKET/assets" --cache-control "public,max-age=31536000,immutable"
fi

# 2. Media keeps a fixed name, so it is cached for a day only.
if [ -d "$SITE/media" ]; then
  aws s3 sync "$SITE/media" "s3://$BUCKET/media" --cache-control "public,max-age=86400" --delete
fi

# 3. Everything else (index.html) goes last and is never cached, so nobody is sent a page that
#    points at files which are not uploaded yet.
aws s3 sync "$SITE" "s3://$BUCKET" --exclude "assets/*" --exclude "media/*" --cache-control "no-cache" --delete

aws cloudfront create-invalidation --distribution-id "$DISTRIBUTION_ID" --paths "/index.html" "/media/*" > /dev/null

echo "Published $SITE to s3://$BUCKET and refreshed CloudFront ($DISTRIBUTION_ID)."
