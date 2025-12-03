# ROL.Church Sync Scripts

This directory contains Ruby scripts that sync data from external services (Planning Center, Facebook, Cloudflare) to generate static JSON data files and images for the website.

## Quick Start

```bash
# Run all scripts (daily sync)
bundle exec ruby sync_all.rb

# Run individual scripts
bundle exec ruby sync_events.rb
bundle exec ruby sync_groups.rb
bundle exec ruby sync_hero_images.rb
```

## Architecture Overview

```
                    ┌─────────────────┐
                    │   sync_all.rb   │
                    │  (orchestrator) │
                    └────────┬────────┘
                             │
         ┌───────────────────┼───────────────────┐
         │                   │                   │
         ▼                   ▼                   ▼
   ┌──────────┐        ┌──────────┐        ┌──────────┐
   │ Group 1  │        │ Group 1  │        │ Group 1  │
   │ Parallel │        │ Parallel │        │ Parallel │
   └────┬─────┘        └────┬─────┘        └────┬─────┘
        │                   │                   │
        ▼                   ▼                   ▼
  sync_events.rb    sync_groups.rb    sync_facebook_photos.rb
  sync_team.rb      sync_cloudflare_video.rb
        │                   │                   │
        └───────────────────┼───────────────────┘
                            │
                            ▼
                    ┌──────────────┐
                    │   Group 2    │
                    │ (sequential) │
                    └──────┬───────┘
                           │
                           ▼
                   sync_hero_images.rb
                           │
                           ▼
                    ┌──────────────┐
                    │   Outputs    │
                    └──────────────┘
                           │
        ┌──────────────────┼──────────────────┐
        ▼                  ▼                  ▼
   src/data/*.json   public/hero/*    public/groups/*
```

## Scripts Reference

### Core Scripts

| Script | Purpose | Runtime | Output |
|--------|---------|---------|--------|
| `sync_all.rb` | Orchestrates all scripts | 30-60s | Email report |
| `sync_events.rb` | Syncs calendar events | 3-5s | `events.json`, `featured_event.json` |
| `sync_groups.rb` | Syncs ministry groups | 10-30s | `groups.json`, images |
| `sync_hero_images.rb` | Syncs hero slider images | 5-15s | `hero_images.json`, images |
| `sync_team.rb` | Syncs team profiles | 2-5s | `team.json`, images |
| `sync_cloudflare_video.rb` | Syncs latest video | 2-4s | `cloudflare_video.json`, `live.astro` |
| `sync_facebook_photos.rb` | Syncs FB photos | 30-120s | `fb_*.jpg`, `facebook_sync_state.json` |

### Shared Modules

| Module | Purpose |
|--------|---------|
| `pco_client.rb` | Planning Center API singleton client |
| `image_utils.rb` | Image download, resize, compression, WebP generation |

## Data Flow

### Events
```
Planning Center Calendar API
         │
         ▼
   sync_events.rb
         │
         ├── src/data/events.json (all events, 12 weeks)
         └── src/data/featured_event.json (hello bar)
```

### Groups
```
Planning Center Groups API
         │
         ▼
   sync_groups.rb
         │
         ├── src/data/groups.json
         ├── public/groups/{slug}_header.jpg
         └── public/groups/{slug}_leader_{id}.jpg
```

### Hero Images
```
Planning Center Media    Facebook Page
         │                    │
         │                    ▼
         │           sync_facebook_photos.rb
         │                    │
         │                    ▼
         └──────────► sync_hero_images.rb
                             │
                             ├── src/data/hero_images.json
                             ├── public/hero/1.jpg, 2.jpg, ... (PCO)
                             ├── public/hero/header_*.jpg (page headers)
                             └── public/hero/fb_*.jpg (Facebook)
```

## Environment Variables

### Required for All Scripts
```bash
ROL_PLANNING_CENTER_CLIENT_ID    # Planning Center Personal Access Token ID
ROL_PLANNING_CENTER_SECRET       # Planning Center Personal Access Token Secret
```

### Script-Specific

| Variable | Scripts | Description |
|----------|---------|-------------|
| `PCO_WEBSITE_HERO_MEDIA_ID` | hero_images, facebook_photos | PCO Services Media ID |
| `CLOUDFLARE_ACCOUNT_ID` | cloudflare_video | Cloudflare account ID |
| `CLOUDFLARE_API_TOKEN` | cloudflare_video | Cloudflare API token |
| `FB_PAGE_ID` | facebook_photos | Facebook page ID |
| `FB_PAGE_ACCESS_TOKEN` | facebook_photos | Facebook System User Token |
| `AWS_ACCESS_KEY_ID` | facebook_photos, sync_all | AWS credentials |
| `AWS_SECRET_ACCESS_KEY` | facebook_photos, sync_all | AWS credentials |
| `AWS_REGION` | facebook_photos, sync_all | AWS region (default: us-east-1) |
| `SES_FROM_EMAIL` | sync_all | Email sender (SES verified) |
| `CHANGELOG_EMAIL` | sync_all | Email recipient |

## Performance Optimization

### Parallel Processing

| Script | Threads | What's Parallelized |
|--------|---------|---------------------|
| `sync_all.rb` | 5 | Group 1 scripts |
| `sync_events.rb` | 8 | Event detail API calls |
| `sync_groups.rb` | 6 | Group processing |
| `sync_groups.rb` | 4 | Person detail fetches (per group) |
| `sync_hero_images.rb` | 4 | Image downloads |
| `sync_facebook_photos.rb` | 4 | Photo analysis |
| `sync_facebook_photos.rb` | 4 | Photo saving |

### API Call Optimization

- **Deduplication**: Event IDs are deduplicated before fetching details
- **Include relationships**: Uses `include:` param to batch related data
- **Pagination**: Fetches 100 items per page (API maximum)
- **Skip duplicates**: Facebook photos skip already-synced posts before API calls

## Error Handling

### Log Prefixes

| Prefix | Meaning | Email Behavior |
|--------|---------|----------------|
| `INFO:` | Normal progress | Not included |
| `DEBUG:` | Verbose debugging | Shown in console |
| `WARN:` / `WARNING:` | Non-fatal issue | Shown in console |
| `ERROR:` | Script failure | Included in email, causes exit code 1 |
| `ALERT:` | Action needed | Included in email (separate section) |
| `SUCCESS:` | Task completed | Not included |

### Example Alert Scenarios

- Featured event has no description or image
- No featured event is set in Planning Center
- Facebook photo sync found qualifying photos to review

## Image Processing

### Size Presets

| Type | Dimensions | Use Case |
|------|------------|----------|
| `:hero` | 1920x1080 | Home page slider |
| `:header` | 1200x600 | Page hero backgrounds |
| `:leader` | 400x400 | Group leader avatars |
| `:team` | 1200x1200 | Pastor/team photos |

### Compression

- **JPEG**: 80% quality
- **WebP**: 65% quality (~30-50% smaller than JPEG)

### Platform Support

- **macOS**: Uses `sips` (built-in) + `cwebp` (optional, via homebrew)
- **Linux**: Uses ImageMagick (`convert`) + `cwebp`

## Facebook Photo Qualification

Photos must meet ALL criteria:

1. **People count**: ≥3 people detected
2. **Smiling**: ≥1 person smiling OR ≥60% of people smiling
3. **Smile confidence**: 70% threshold
4. **Text detection**: ≤3 text elements (filters screenshots/slides)

Photos are smart-cropped to 16:9 with faces positioned at 1/3 from top (rule of thirds).

### Storage and Display Limits

- **Planning Center**: ALL qualifying photos are uploaded (no limit) for archival
- **Website slider**: Only the 5 most recent photos are displayed (see `HeroSlider.astro`)
- **AWS Rekognition**: Only analyzes NEW photos (tracked by post ID to save costs)

The script never deletes images from Planning Center - it only adds new qualifying photos.

## File Naming Conventions

### Hero Images
- `1.jpg`, `2.jpg`, etc. - PCO-sourced slider images
- `header_pastor.jpg` - Page header for /pastor
- `header_next_steps_visit.jpg` - Page header for /next-steps/visit
- `fb_20241201_12345.jpg` - Facebook photo (date + post ID)

### Group Images
- `{slug}_header.jpg` - Group header background
- `{slug}_leader_{person_id}.jpg` - Leader avatar

### Team Images
- `{slug}.jpg` - Team member photo (e.g., `andrew_coffield.jpg`)

## Deletion Tracking (Facebook)

If you manually delete a `fb_*.jpg` file from `public/hero/`:

1. `sync_facebook_photos.rb` detects the missing file
2. Adds the post ID to `deleted_post_ids` in state file
3. That photo will NOT be re-synced in future runs

This prevents unwanted photos from coming back after manual curation.

## GitHub Actions Integration

The scripts are designed to run in GitHub Actions:

```yaml
# .github/workflows/daily-sync.yml
- name: Sync data
  env:
    ROL_PLANNING_CENTER_CLIENT_ID: ${{ secrets.ROL_PLANNING_CENTER_CLIENT_ID }}
    ROL_PLANNING_CENTER_SECRET: ${{ secrets.ROL_PLANNING_CENTER_SECRET }}
    # ... other secrets
  run: bundle exec ruby scripts/sync_all.rb
```

Exit codes:
- `0` - Success (or no changes)
- `1` - Errors occurred (check email report)

## Local Development

1. Copy `.envrc.example` to `.envrc`
2. Fill in credentials
3. Run `direnv allow`
4. Run scripts with `bundle exec ruby sync_*.rb`

## Troubleshooting

### "No featured event" warning
Set an event as "Featured" in Planning Center Calendar.

### Images not downloading
Check `PCO_WEBSITE_HERO_MEDIA_ID` is correct. Verify the Media item exists in Planning Center Services.

### Facebook sync not finding photos
Ensure `FB_PAGE_ACCESS_TOKEN` has permissions for the page. Token may need refresh.

### AWS Rekognition errors
Check AWS credentials. Ensure the IAM user has `rekognition:DetectFaces` and `rekognition:DetectText` permissions.
