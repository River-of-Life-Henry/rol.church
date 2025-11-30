# River of Life Church Website

The official website for **River of Life Church**, an Apostolic Pentecostal church in Henry, IL. Built with [Astro](https://astro.build).

**Live site:** [rol.church](https://rol.church)

## Quick Start

```bash
# Install dependencies
npm install

# Start development server
npm run dev

# Start dev server accessible on local network (for mobile testing)
npm run dev -- --host

# Build for production
npm run build
```

## Features

- **Responsive design** - Works great on desktop, tablet, and mobile
- **Live streaming** - Cloudflare Stream integration with countdown timer
- **Dynamic events** - Synced from Planning Center Calendar
- **Ministry groups** - Group pages with leaders and upcoming events
- **Pastor page** - Full-width photo layout with bio from Planning Center
- **Rotating testimonials** - Google and Facebook reviews with flip animation
- **Analytics** - Google Analytics, Microsoft Clarity, Meta Pixel

## Updating Content

Content is managed through **Planning Center** and synced to the website automatically.

### Events

1. Go to [Planning Center Calendar](https://calendar.planningcenteronline.com/events)
2. Create or edit an event
3. Make sure the event is:
   - **Visible in Church Center** (checked)
   - Not tagged as "Hidden"
4. Events sync automatically daily at 6 AM CT

**Featured Events (Hello Bar):**
- Mark an event as "Featured" (star icon) to display it in the hello bar
- Featured events also get their own page at `/events/[slug]`
- Add a header image and description for best results

### Groups/Ministries

1. Go to [Planning Center Groups](https://groups.planningcenteronline.com/groups)
2. Create or edit a group
3. Enable **Church Center Visible**

**What syncs to the website:**
- **Header image** - Group's header image
- **Description** - Group description text
- **Schedule** - Meeting schedule (e.g., "Every Wednesday at 7pm")
- **Leaders** - Members with role set to "Leader" (photos from People profiles)
- **Contact email** - Group contact email

### Hero Slider Images

Hero images are managed through Planning Center Services Media.

**Location:** [Planning Center Media - Website Hero Images](https://services.planningcenteronline.com/medias/3554537)

**Two types of images:**
1. **Home Page Slider** - Any image without `header_` prefix
2. **Page Headers** - Files prefixed with `header_` (e.g., `header_about.jpg`)

Images are automatically resized (max 1920×1080), compressed, and converted to WebP.

### Pastor & Team

1. Go to [Planning Center People](https://people.planningcenteronline.com)
2. Find the person's profile
3. Go to the **"Website - ROL.Church"** tab
4. Update Position Title and Bio
5. Update profile photo if needed

**Currently synced:** Andrew Coffield (Pastor), Christopher Huff (Foundations)

### Profile Photos

All profile photos on the website are synced from Planning Center People profiles:

- **Pastor page** (`/pastor`) - From Pastor Andrew's People profile
- **Group pages** (`/groups/*`) - Leader photos from each leader's People profile
- **Foundations page** (`/next-steps/foundations`) - From Christopher Huff's People profile

To update a photo, update it in Planning Center People → person's profile → profile photo.

### Live Stream (Cloudflare Stream)

The live page uses **Cloudflare Stream** for live streaming and recorded services.

- Live stream auto-detects when broadcasting
- Latest Sunday service recording displays when not live
- Countdown timer shows before next service

**Video sync runs:**
- Daily at 6 AM CT
- Sundays at 1 PM and 2 PM CT (to catch the latest service)

### Facebook Photos (Hero Slider) - Automatic

The hero slider on the home page is **automatically populated** with photos from the church Facebook page. No manual work required!

**How it works:**
1. Daily at 6 AM CT, the sync fetches recent photos from the [River of Life Facebook page](https://www.facebook.com/rolhenry)
2. Each photo is analyzed by AWS Rekognition (AI) to detect:
   - Number of people in the photo
   - Whether people are smiling
   - Any text overlays (to reject slides/screenshots)
3. Photos that qualify (3+ people, at least 1 smiling, no text) are:
   - Smart cropped to position faces at 1/3 from top
   - Optimized and converted to WebP
   - Added to the hero slider
   - Uploaded to Planning Center Media for backup/management

**Qualification criteria:**
- At least 3 people visible
- At least 1 person smiling (or 60%+ smiling)
- No text overlays (rejects slides, graphics, screenshots)

**Managing photos:**
- Photos sync automatically - just post good group photos to Facebook!
- To remove a photo from the slider, delete it from Planning Center Media (it won't re-sync)
- Manual hero images can still be added via Planning Center Media with `header_` prefix

## Sync Scripts

All sync scripts are in the `scripts/` directory:

```bash
cd scripts
bundle install  # First time only

# Sync everything
ruby sync_all.rb

# Individual syncs
ruby sync_events.rb          # Events from Planning Center Calendar
ruby sync_groups.rb          # Groups from Planning Center Groups
ruby sync_hero_images.rb     # Hero images from Planning Center Media
ruby sync_team.rb            # Team members from Planning Center People
ruby sync_cloudflare_video.rb # Latest video from Cloudflare Stream
ruby sync_facebook_photos.rb  # Photos from Facebook (smile detection)
```

**Environment variables required:**
- `ROL_PLANNING_CENTER_CLIENT_ID` - Planning Center API credentials
- `ROL_PLANNING_CENTER_SECRET`
- `CLOUDFLARE_API_TOKEN` - For video sync
- `CLOUDFLARE_ACCOUNT_ID`
- `FB_PAGE_ID` - Facebook Page ID (for photo sync)
- `FB_PAGE_ACCESS_TOKEN` - Facebook System User Token
- `AWS_ACCESS_KEY_ID_ROL` - AWS credentials for Rekognition (smile detection)
- `AWS_SECRET_ACCESS_KEY_ROL`

### Automatic Syncing (GitHub Actions)

| Workflow | Schedule | Description |
|----------|----------|-------------|
| `sync-pco.yml` | Daily 6 AM CT | Full sync (PCO + Facebook photos + Cloudflare video) |
| `sync-cloudflare-video.yml` | Daily 6 AM CT + Sundays 1 PM & 2 PM CT | Latest video sync |
| `deploy.yml` | On push to main | Build and deploy |

## Project Structure

```
/
├── public/
│   ├── hero/           # Hero slider images
│   ├── groups/         # Group images and leader photos
│   └── team/           # Team member photos
├── src/
│   ├── components/     # Reusable Astro components
│   │   ├── HeroSlider.astro
│   │   └── PageHero.astro
│   ├── data/           # JSON data (auto-generated)
│   │   ├── events.json
│   │   ├── featured_event.json
│   │   ├── groups.json
│   │   ├── hero_images.json
│   │   └── team.json
│   ├── layouts/
│   │   └── Base.astro  # Main layout (header, footer, analytics)
│   └── pages/          # Website pages
├── scripts/            # Ruby sync scripts
└── .github/workflows/  # GitHub Actions
```

## Pages

| Route | Description |
|-------|-------------|
| `/` | Home page with hero slider and rotating testimonials |
| `/live` | Live stream / latest service recording |
| `/events` | Upcoming events calendar |
| `/events/[slug]` | Featured event detail pages |
| `/groups` | Ministry groups overview |
| `/groups/[slug]` | Individual group pages |
| `/pastor` | Senior pastor page |
| `/about` | About the church |
| `/contact` | Contact information |
| `/directions` | Location and directions |
| `/give` | Online giving |
| `/next-steps/visit` | Plan your visit |
| `/next-steps/baptism` | Baptism information |
| `/next-steps/foundations` | Foundations class |
| `/next-steps/volunteer` | Volunteer opportunities |

## Making Changes

### Edit Navigation or Footer

Edit `src/layouts/Base.astro` - contains header, navigation, footer, and analytics.

### Add a New Page

1. Create a new `.astro` file in `src/pages/`
2. Import the Base layout: `import Base from '../layouts/Base.astro';`
3. Wrap content in `<Base title="Page Title">...</Base>`
4. Add navigation link in `Base.astro` if needed

## Development

```bash
# Start dev server with hot reload
npm run dev

# Dev server on local network (mobile testing)
npm run dev -- --host

# Type checking
npm run astro check

# Build and preview production
npm run build && npm run preview
```

## Deployment

The site is hosted on **GitHub Pages** at [rol.church](https://rol.church).

Deployment happens automatically when changes are pushed to the `main` branch.

## Analytics

Tracking includes:
- **Google Analytics 4** - Page views, events
- **Microsoft Clarity** - Session recordings, heatmaps
- **Meta Pixel** - Facebook conversion tracking

Events tracked: page views, CTA clicks, form opens, scroll depth, time on page.

## Timezone

All event times are displayed in **Chicago time (Central Time)**.

## Content Update Checklist

### Weekly Updates

| Item | Where to Update | What It Updates | Link |
|------|-----------------|-----------------|------|
| Featured Event (Hello Bar) | Calendar → Event → Toggle "Featured" star | Yellow banner at top of every page | [Calendar Events](https://calendar.planningcenteronline.com/events) |
| Upcoming Events | Calendar → Create/Edit Event | Events page listing | [Calendar Events](https://calendar.planningcenteronline.com/events) |

### As Needed Updates (synced daily at 6 AM CT)

| Item | Where to Update | What It Updates | Link |
|------|-----------------|-----------------|------|
| Group Info | Groups → Edit Group | Group page content | [Groups](https://groups.planningcenteronline.com/groups) |
| Group Leaders | Groups → Members → Set role "Leader" | Leader photos/names on group pages | [Groups](https://groups.planningcenteronline.com/groups) |
| Group Events | Calendar → Create Event → Tag with group name | Events shown on group pages | [Calendar Events](https://calendar.planningcenteronline.com/events) |
| Pastor Bio | People → Andrew Coffield → "Website - ROL.Church" tab | Pastor page text | [People](https://people.planningcenteronline.com) |
| Pastor Photo | People → Andrew Coffield → Profile Photo | Pastor page image | [People](https://people.planningcenteronline.com) |
| Hero Slider Images | Services → Media → "Website Hero Images" | Home page slider background | [Media](https://services.planningcenteronline.com/medias/3554537) |

### Automatic (No Action Needed)

| Item | How It Works | Frequency |
|------|--------------|-----------|
| Hero Slider Photos | AI selects good group photos from Facebook (3+ people, smiling) | Daily 6 AM CT |
| Live Stream | Cloudflare detects when streaming | Real-time |
| Latest Service Recording | Syncs from Cloudflare Stream | Daily + After Sunday service |
| Service Countdown Timer | Calculated automatically | Real-time |
| Profile Photos | Synced from Planning Center People profiles | Daily 6 AM CT |

### Quick Links

| Platform | Link |
|----------|------|
| Planning Center Calendar | https://calendar.planningcenteronline.com/events |
| Planning Center Groups | https://groups.planningcenteronline.com/groups |
| Planning Center People | https://people.planningcenteronline.com |
| Hero Images Media | https://services.planningcenteronline.com/medias/3554537 |
| Church Center (Public) | https://rolhenry.churchcenter.com |
| Cloudflare Dashboard | https://dash.cloudflare.com |
| Facebook Page | https://www.facebook.com/rolhenry |
| GitHub Repository | https://github.com/River-of-Life-Henry/rol.church |

## Quick Reference

| Content | Source | Sync Script |
|---------|--------|-------------|
| Events | Planning Center Calendar | `sync_events.rb` |
| Featured Event | Calendar → Toggle "Featured" star | `sync_events.rb` |
| Groups | Planning Center Groups | `sync_groups.rb` |
| Group Leaders | Groups → Members → Role: Leader | `sync_groups.rb` |
| Hero Images (manual) | Services → Media → "Website Hero Images" | `sync_hero_images.rb` |
| Hero Images (auto) | Facebook page photos | `sync_facebook_photos.rb` |
| Pastor Info | People → "Website - ROL.Church" tab | `sync_team.rb` |
| Live Video | Cloudflare Stream | `sync_cloudflare_video.rb` |
