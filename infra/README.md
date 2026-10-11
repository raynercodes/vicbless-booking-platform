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
