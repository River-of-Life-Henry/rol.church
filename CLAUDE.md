# River of Life Church Website - AI Context

This is the official website for **River of Life Church**, an Apostolic Pentecostal church in Henry, IL.

**Live URL:** https://rol.church
**Dev URL:** https://dev.rol.church (Cloudflare Pages preview)
**Repository:** https://github.com/River-of-Life-Henry/rol.church

## Technology Stack

- **Framework:** Astro 5.x (static site generator)
- **Styling:** CSS-in-JS with scoped and global styles
- **Data Sync:** Ruby scripts pulling from Planning Center API
- **Deployment:** GitHub Pages via GitHub Actions
- **Analytics:** Google Analytics 4, Microsoft Clarity, Meta Pixel
- **Error Monitoring:** Bugsnag (client-side, sync scripts)
- **Webhooks:** AWS Lambda (Ruby 3.2) via Serverless Framework
- **Video:** Cloudflare Stream for service recordings

## Project Structure

```
src/
├── components/
│   ├── layout/             # Layout components
│   │   ├── Analytics.astro # GA4, Clarity, Meta Pixel, Bugsnag
│   │   ├── Header.astro    # Navigation, hamburger menu
│   │   ├── Footer.astro    # Footer with service times
│   │   ├── HelloBar.astro  # Top announcement bar
│   │   └── EventTracking.astro # Click/scroll tracking
│   ├── home/               # Home page components
│   │   ├── HeroSlider.astro
│   │   ├── HeroCards.astro
│   │   └── TestimonialsCarousel.astro
│   ├── shared/             # Reusable components
│   │   ├── PageHero.astro
│   │   ├── EventCard.astro
│   │   └── GroupCard.astro
│   └── utils/              # Utility components
│       ├── MapEmbed.astro
│       └── PlanningCenterForm.astro
├── layouts/
│   └── Base.astro          # Main layout wrapper
├── pages/                  # URL routes (file-based routing)
│   ├── index.astro         # Home page
│   ├── events/
│   │   ├── index.astro     # Events listing
│   │   └── [slug].astro    # Individual event pages
│   ├── groups/
│   │   ├── index.astro     # Groups overview
│   │   └── [slug].astro    # Dynamic group pages
│   ├── about/
│   │   ├── index.astro     # About page
│   │   ├── pastor.astro    # Pastor page
│   │   └── contact.astro   # Contact page
│   ├── next-steps/         # Visitor journey pages
│   └── live.astro          # Live stream page
└── data/                   # JSON data (auto-generated - DO NOT EDIT)
    ├── events.json         # From Planning Center Calendar
    ├── featured_event.json # Featured event for hello bar
    ├── groups.json         # From Planning Center Groups
    ├── team.json           # Team member profiles
    ├── hero_images.json    # From Planning Center Media + Facebook
    ├── cloudflare_video.json # Latest service recording
    └── facebook_sync_state.json # Facebook photo sync tracking

scripts/                    # Ruby sync scripts (run in GitHub Actions)
├── sync_all.rb             # Master orchestrator
├── sync_events.rb          # Planning Center Calendar
├── sync_groups.rb          # Planning Center Groups
├── sync_hero_images.rb     # Hero slider images
├── sync_facebook_photos.rb # AI-powered photo selection
├── sync_team.rb            # Team member profiles
├── sync_cloudflare_video.rb # Cloudflare Stream video
├── pco_client.rb           # Planning Center API client
└── image_utils.rb          # Image optimization

webhooks/                   # AWS Lambda webhook handler
├── handler.rb              # Main Lambda function
├── serverless.yml          # Infrastructure as code
├── Gemfile                 # Ruby dependencies
└── lib/                    # Supporting modules
    ├── webhook_verifier.rb
    ├── github_trigger.rb
    └── webhook_logger.rb

.github/workflows/          # GitHub Actions
├── deploy.yml              # Deploy to GitHub Pages
├── daily-sync.yml          # Sync data every 6 hours
├── sync-cloudflare-video.yml # Sunday video sync
└── deploy-webhooks.yml     # Deploy Lambda

public/
├── hero/                   # Hero slider images
├── groups/                 # Group headers and leader photos
├── team/                   # Pastor photo
└── logo.png, favicon.png   # Brand assets
```

## Key Files

### `src/layouts/Base.astro` (Most Important)
Contains:
- HTML head with meta tags, SEO, structured data (JSON-LD)
- Google Analytics, Clarity, Meta Pixel scripts
- Header with navigation (responsive with hamburger menu)
- Footer with service times, location, contact, social links
- All global CSS styles including:
  - CSS variables (colors, fonts)
  - Navigation styles (desktop + mobile)
  - Footer styles
  - Button/link styles

### `src/pages/events.astro`
- Displays events from `events.json`
- Groups events by month
- Limited to 6 weeks ahead
- All times displayed in Chicago timezone (`America/Chicago`)

### `src/pages/pastor.astro`
- Static page showing pastor info (hardcoded, not synced)
- Previously was `/team` with multiple team members

### `src/pages/groups/[slug].astro`
- Dynamic pages for each ministry group
- Shows group description, upcoming events, leaders
- Events filtered by group name/tags

## Design System

### Colors (CSS Variables)
- `--color-teal: #2d9cca` - Primary accent
- `--color-teal-dark: #1a7ba8` - Hover states
- `--color-gold: #f5c542` - Highlights, tagline
- `--color-navy: #1a3a4a` - Text, headers, footer background
- `--color-navy-light: #2a4a5a` - Secondary navy

### Fonts
- **Montserrat** (`--font-sans`) - Body text, headings
- **Dancing Script** (`--font-script`) - Decorative tagline "Where life begins"

### Breakpoints
- Mobile menu: `900px`
- Stack layouts: `768px`

## Common Tasks

### Add/Edit a Page
1. Create/edit `.astro` file in `src/pages/`
2. Import Base layout: `import Base from '../layouts/Base.astro';`
3. Wrap content: `<Base title="Page Title">content</Base>`
4. Add navigation link in `Base.astro` if needed

### Update Navigation
Edit `src/layouts/Base.astro` around line 170-198:
- Main nav items in `.nav-menu`
- Dropdown menus in `.has-dropdown > .dropdown`

### Update Footer
Edit `src/layouts/Base.astro` around line 430-488:
- Service times, location, contact info, social links

### Change Styles
- Global styles: `<style is:global>` in `Base.astro`
- Page-specific: `<style>` in individual page files
- Component-specific: `<style>` in component files

### Sync Data from Planning Center
```bash
cd scripts
ruby sync_all.rb  # Or individual scripts
```
Requires environment variables:
- `ROL_PLANNING_CENTER_CLIENT_ID`
- `ROL_PLANNING_CENTER_SECRET`

## Important Conventions

1. **Timezone:** All event times use Chicago timezone (`America/Chicago`)
   - Ruby scripts: `ENV['TZ'] = 'America/Chicago'` at top
   - Frontend: `timeZone: 'America/Chicago'` in toLocaleTimeString

2. **SEO:** Each page should have:
   - Descriptive title via `<Base title="...">`
   - Description via `<Base description="...">`

3. **Analytics:** All user interactions should be tracked to GA4, Microsoft Clarity, and Meta Pixel
   - Use the `trackEvent()` function in Base.astro for custom events
   - CTAs, form opens, navigation clicks, scroll depth, and time on page are auto-tracked
   - When adding new interactive elements, ensure they are tracked

4. **Images:**
   - Hero images: `/public/hero/`
   - Group images: `/public/groups/`
   - Pastor photo: `/public/team/andrew_coffield.jpg`

5. **Data Files:** Never edit files in `src/data/` manually - they're auto-generated by sync scripts

6. **Documentation:** Always keep README.md up to date when making changes to the site
   - Document new features
   - Update instructions if workflows change
   - Keep Planning Center sync instructions current

7. **SEO & AI Optimization:** Every site update should consider SEO and AI discoverability
   - Use semantic HTML (proper H1, H2, H3 hierarchy)
   - Include "River of Life" and "Apostolic Pentecostal church" in key pages
   - Write descriptive meta descriptions
   - Use alt text for images
   - Maintain structured data (JSON-LD) in Base.astro
   - Home page has a visually-hidden H1 with full church name for SEO
   - Use `.sr-only` class for SEO-important but visually hidden content

8. **Address Linking:** Every time the church address (425 University Ave, Henry, IL) appears on the site, it MUST link to the `/directions` page

9. **Button Icons:** All buttons (`.btn`, `.btn-large`) should have SVG icons for visual appeal

## Church Identity

- **Name:** River of Life (ROL)
- **Denomination:** Apostolic Pentecostal
- **Location:** 425 University Ave, Henry, IL 61537
- **Tagline:** "Where life begins"
- **Pastor:** Andrew & Chelsea Coffield
- **Service Times:**
  - Sunday: 10am (Christian Education), 11am (Worship Service)
  - Wednesday: 7pm (Bible Study)

## SEO Keywords
Include naturally in content:
- River of Life, ROL Henry
- Apostolic Pentecostal church
- Henry IL church
- Pentecostal church near me

## Error Monitoring (Bugsnag)

Bugsnag is integrated across all components of the system.

**API Key:** `d40fd193e2e3a965cee32be1243fcee3`
**Dashboard:** https://app.bugsnag.com/

### Client-Side (Browser)
- **Location:** `src/components/layout/Analytics.astro`
- **What's tracked:** JavaScript errors on the live website
- Automatically detects production vs development based on hostname (`rol.church` = production)
- Does not collect user IP addresses
- **Important:** Script loads via `onload` callback to ensure `Bugsnag.start()` runs after library loads

### Ruby Sync Scripts
- **Location:** `scripts/sync_all.rb`
- **What's tracked:** Errors from all sync scripts (events, groups, hero images, etc.)
- Errors are reported with script name metadata
- Environment: `BUGSNAG_API_KEY` passed in GitHub Actions

### AWS Lambda (Webhook Handler)
- **Location:** `webhooks/handler.rb`
- **Status:** Bugsnag is optional (gracefully disabled if gem not bundled)
- Serverless Framework doesn't auto-bundle Ruby gems, so Bugsnag requires manual setup
- Errors still logged to CloudWatch

### GitHub Actions Build Reporting
- **Location:** `.github/workflows/deploy.yml`
- **What's tracked:** Successful builds with source control info
- Associates errors with specific commits/builds

### Required GitHub Secret
- `BUGSNAG_API_KEY` - Already configured in repository secrets

## GitHub Actions Workflows

### deploy.yml - Deploy to GitHub Pages
- **Triggers:** Push to main (except webhooks/), manual
- **What it does:** Builds Astro site, deploys to GitHub Pages, notifies Bugsnag
- **Concurrency:** Only one deployment at a time (no cancel-in-progress)

### daily-sync.yml - Sync Data from Planning Center
- **Triggers:** Every 6 hours, manual, webhook
- **What it does:** Runs all sync scripts, commits changes, triggers deploy
- **Concurrency:** Cancel queued runs if new one triggered (keep running one)
- **Retry logic:** Up to 3 attempts for git push conflicts

### deploy-webhooks.yml - Deploy Lambda
- **Triggers:** Push to webhooks/, manual
- **What it does:** Deploys Lambda via Serverless Framework, verifies webhooks
- **Concurrency:** Only one deployment at a time (waits for in-progress)
- **Note:** Simultaneous deployments cause CloudFormation errors

### sync-cloudflare-video.yml - Sunday Video Sync
- **Triggers:** Sunday afternoons after service
- **What it does:** Syncs latest video from Cloudflare Stream

## AWS Lambda Webhook Handler

**Endpoint:** `https://7mirffknzi.execute-api.us-east-1.amazonaws.com/prod`
**Health Check:** `GET /health`

### Endpoints
- `POST /webhook/pco` - Planning Center webhooks (logged only, not triggering workflows)
- `POST /webhook/cloudflare` - Cloudflare Stream webhooks (triggers sync)
- `GET /health` - Health check

### Infrastructure
- **Runtime:** Ruby 3.2
- **Region:** us-east-1
- **Memory:** 256MB
- **Timeout:** 30s
- **Database:** DynamoDB for webhook logs (90-day TTL)

### Environment Variables (in serverless.yml)
- `GITHUB_PAT` - GitHub token for triggering workflows
- `GITHUB_REPO` - Repository name
- `CLOUDFLARE_WEBHOOK_SECRET` - Webhook signature verification
- `BUGSNAG_API_KEY` - Error reporting (optional)

## GitHub Secrets Required

| Secret | Purpose |
|--------|---------|
| `ROL_PLANNING_CENTER_CLIENT_ID` | Planning Center API |
| `ROL_PLANNING_CENTER_SECRET` | Planning Center API |
| `PCO_WEBSITE_HERO_MEDIA_ID` | PCO Media ID for hero images |
| `CLOUDFLARE_API_TOKEN` | Cloudflare Stream API |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare account |
| `CLOUDFLARE_WEBHOOK_SECRET` | Webhook verification |
| `FB_PAGE_ID` | Facebook page ID |
| `FB_PAGE_ACCESS_TOKEN` | Facebook API token |
| `AWS_ACCESS_KEY_ID_ROL` | AWS credentials |
| `AWS_SECRET_ACCESS_KEY_ROL` | AWS credentials |
| `SES_FROM_EMAIL` | SES verified sender |
| `WEBHOOKS_GITHUB_PAT` | GitHub PAT for webhook Lambda |
| `BUGSNAG_API_KEY` | Error monitoring |

## Common Gotchas & Lessons Learned

### Astro Script Loading
- Scripts with `src` attribute are loaded async by default
- Use `is:inline` for scripts that need to run immediately
- For external scripts that need initialization, use `onload` callback:
  ```javascript
  var script = document.createElement('script');
  script.src = 'https://example.com/lib.js';
  script.onload = function() { /* init here */ };
  document.head.appendChild(script);
  ```

### Ruby Lambda Deployment
- Serverless Framework doesn't auto-bundle Ruby gems
- Gems must be vendored or made optional with `rescue LoadError`
- Local Ruby version may differ from Lambda (3.2.0 in Lambda)

### GitHub Actions Concurrency
- Use `cancel-in-progress: false` when deployments shouldn't be interrupted
- Use `cancel-in-progress: true` for sync jobs where latest data matters
- CloudFormation errors occur if two Lambda deployments run simultaneously

### Planning Center API
- All times should use `America/Chicago` timezone
- Use `include:` parameter to reduce API calls
- Pagination: fetch all pages with offset/per_page

### Event Filtering
- Events are filtered by end time, not start time (prevents showing past events)
- 6-week window for event display

### Image Processing
- ImageMagick 7 uses `magick` command, v6 uses `convert` - code detects both
- WebP generation requires `cwebp` (preferred) or ImageMagick
- Hero images must have both .jpg and .webp versions (HeroSlider expects both)
- `image_utils.rb` auto-generates webp when optimizing images
