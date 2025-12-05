/**
 * Event Filtering Utilities
 *
 * Shared utilities for filtering events by date/time.
 * All filtering uses Central Time (America/Chicago).
 */

export interface Event {
  id: string;
  name: string;
  slug?: string;
  description?: string;
  startsAt: string;
  endsAt?: string;
  location?: string;
  allDay?: boolean;
  tags?: string[];
  featured?: boolean;
  imageUrl?: string;
  registrationUrl?: string;
}

/**
 * Get the effective end time for an event.
 * Uses endsAt if available, otherwise falls back to startsAt.
 * For all-day events without an end time, uses end of day (11:59 PM Central).
 */
export function getEventEndTime(event: Event): Date {
  if (event.endsAt) {
    return new Date(event.endsAt);
  }

  // Fall back to start time if no end time
  const startDate = new Date(event.startsAt);

  // For all-day events, use end of day
  if (event.allDay) {
    // Set to 11:59:59 PM on the same day
    startDate.setHours(23, 59, 59, 999);
  }

  return startDate;
}

/**
 * Check if an event has ended (based on end time in Central Time).
 */
export function hasEventEnded(event: Event, now: Date = new Date()): boolean {
  const endTime = getEventEndTime(event);
  return endTime < now;
}

/**
 * Filter out events that have already ended.
 * Events are considered ended when their endsAt time has passed.
 */
export function filterPastEvents(events: Event[], now: Date = new Date()): Event[] {
  return events.filter(event => !hasEventEnded(event, now));
}

/**
 * Filter events for the main events page.
 * - Regular events: within 6 weeks
 * - Featured events: within 12 weeks
 * - Excludes events that have ended
 */
export function filterEventsForDisplay(events: Event[], now: Date = new Date()): Event[] {
  const sixWeeksFromNow = new Date(now.getTime() + (6 * 7 * 24 * 60 * 60 * 1000));
  const twelveWeeksFromNow = new Date(now.getTime() + (12 * 7 * 24 * 60 * 60 * 1000));

  return events.filter(event => {
    // Filter out ended events
    if (hasEventEnded(event, now)) return false;

    const eventDate = new Date(event.startsAt);

    // Featured events can be up to 12 weeks out
    if (event.featured) return eventDate <= twelveWeeksFromNow;

    // Regular events only within 6 weeks
    return eventDate <= sixWeeksFromNow;
  });
}

/**
 * Group events by month for display.
 */
export function groupEventsByMonth(events: Event[]): Record<string, Event[]> {
  const grouped: Record<string, Event[]> = {};

  events.forEach(event => {
    const date = new Date(event.startsAt);
    const monthKey = date.toLocaleDateString('en-US', {
      month: 'long',
      year: 'numeric',
      timeZone: 'America/Chicago'
    });

    if (!grouped[monthKey]) {
      grouped[monthKey] = [];
    }
    grouped[monthKey].push(event);
  });

  return grouped;
}
