/**
 * Ministry Justification Categories
 *
 * Each ministry has predefined budget categories that were approved.
 * This allows tracking of expense requests against approved budget items.
 *
 * "Other (Please Specify)" is automatically added as the last option for each ministry.
 */

export const MINISTRY_JUSTIFICATIONS: Record<string, string[]> = {
  // 1. MD Prayer
  "MD Prayer": [
    "Yearly prayer mountain trip",
  ],

  // 2. MD Leadership
  "MD Leadership": [
    "Ministry leaders training quarterly",
    "Love gifts for invited guests",
    "Ministries and Leadership related costs",
  ],

  // 3. MD Media
  "MD Media": [
    "Keyboard",
    "Monitor",
    "Drum sub",
    "Drum set accessories",
  ],

  // 4. MD Music
  "MD Music": [
    "Camera lens",
    "SD Cards(x2)",
    "Gimbals",
    "SSD drive",
    "PowerBank(3X)",
    "Tripods(3x)",
    "Back lights(2x)",
  ],

  // 5. MD Young Adult
  "MD Young Adult": [
    "Yearly Retreat",
    "Yearly Outreach 1 - T-Shirt and Tracts Printing",
    "Yearly Outreach 2 - T-Shirt and Tracts Printing",
    "10 Year Celebration Program",
    "Weekly Service",
    "Guest Speakers and/or Ministers",
    "Worship Ministry",
    "Social Media Engagement",
    "Fellowship/Participants engagement",
  ],

  // 6. MD Deacons
  "MD Deacons": [
    "Office Supplies",
    "Lord's supper Preparation Expense",
    "Catering cost on New Year & Thanksgiving",
    "Deacons Retreat Session (Matching Fund)",
  ],

  // 7. MD Women
  "MD Women": [
    "Monthly Meeting",
    "Support for retreat",
    "Training (invite guests)",
  ],

  // 8. MD Men
  "MD Men": [
    "Annual ALIC Men's Retreat support",
    "Group Leaders & Coordinators Meeting",
    "All Men's Meeting",
    "All Men's Virtual Meeting Every 3 months",
  ],

  // 9. MD Evangelism & Discipleship
  "MD Evangelism & Discipleship": [
    "T-Shirt",
    "Track Printing",
    "Posters",
    "Salivation Class Baptism",
    "Discipleship 101 Fellowship",
    "Discipleship 102 Fellowship",
    "Outreach New York",
    "Outreach New Carolina",
    "Outreach Ohio",
    "Outreach Lancaster",
    "Outreach Baltimore",
    "Outreach Virginia",
  ],

  // 10. MD Youth
  "MD Youth": [
    "Spiritual Growth Activities",
    "Leadership Development",
    "Mentorship and Discipleship",
    "Community Engagement and Volunteerism",
    "Worship and Ministry Involvement",
    "Fellowship and Social Events",
    "Parent and Family Involvement",
    "Outreach and Evangelism",
    "Special Events",
    "Regular Feedback and Continuous Improvement",
  ],

  // 11. MD True Vine
  "MD True Vine": [
    "Overseers",
    "Media Department",
    "Evangelism Department",
    "Men's Ministry",
    "Women's Ministry",
    "Coordination Department",
    "Discipleship Department",
    "Prayer Department",
    "Worship Department",
    "Bible Studies Department",
    "Foundations Department",
  ],

  // 12. MD HA Choir
  "MD HA Choir": [
    "Recording Songs (2 songs)",
    "Speaker (Portable PA System - 1600W Active Bluetooth Compatible)",
    "Electric Guitar with all accessories",
    "Stand and pedal for the Keyboard",
    "Training Sessions (2 training sessions)",
    "Get-together",
    "Printing (Choir Songs)",
  ],

  // 13. MD Worship B
  "MD Worship B": [
    "Teaching",
    "Vocal training",
    "Retreat support",
    "Worship team get together",
    "Clothes",
    "Music Band",
    "10th Year Anniversary",
  ],

  // 14. MD Children
  "MD Children": [
    "Parents Training",
    "Baptism",
    "VBS",
    "Parents equip and back to school night",
    "Volunteer/Teachers equip",
    "Christmas party",
    "Curriculum",
    "Miscellaneous",
  ],

  // 15. MD Home Cell (Bible Study groups)
  "MD Home Cell": [
    "Study leaders meeting",
    "Training for previous and new leaders",
    "Home cell groups Unity Day",
    "Coordinator's retreat matching fund",
    "Home cell groups outdoor gatherings",
  ],

  // 16. MD Welcome
  "MD Welcome": [
    "Welcome and celebration for new members",
    "Home visit for sick members",
  ],

  // 17. MD Senior's
  "MD Senior's": [
    "Fellowship",
  ],

  // 18. MD Holistic
  "MD Holistic": [
    "Support for Church Members in need",
    "Education and Training",
  ],

  // 19. MD Counseling & Marriage
  "MD Counseling & Marriage": [
    "Couples' Special Program",
    "Singles Special Program",
    "Couples Fellowship Leaders Training",
  ],

  // 20. MD Serving
  "MD Serving": [
    "Fellowship",
    "Workshop",
  ],

  // 21. MD Grace
  "MD Grace": [
    "Training and development for volunteers",
    "Ministers' prayer and training",
    "Weekly service snacks",
    "Curriculum development and adaptive resources and materials for disability-inclusive studies",
    "Hosting inclusive events, workshops, and community outreach initiatives",
    "Unforeseen expenses and adjustments to the budget",
  ],

  // 22. MD Visiting
  "MD Visiting": [
    "Visiting members meeting",
  ],

  // 23. MD IT
  "MD IT": [
    "Software and Online monthly Subscriptions",
    "Miscellaneous Expense",
  ],

  // 24. MD Parking
  "MD Parking": [
    "Miscellaneous Expense",
  ],
};

// Special value for "Other" option
export const OTHER_JUSTIFICATION_VALUE = "__other__";
export const OTHER_JUSTIFICATION_LABEL = "Other (Please Specify)";

/**
 * Get justification options for a ministry
 * Returns the predefined categories plus "Other (Please Specify)" at the end
 */
export function getJustificationsForMinistry(ministryName: string): string[] {
  // Try exact match first
  if (MINISTRY_JUSTIFICATIONS[ministryName]) {
    return MINISTRY_JUSTIFICATIONS[ministryName];
  }

  // Try case-insensitive match
  const normalizedName = ministryName.toLowerCase().trim();
  for (const [key, values] of Object.entries(MINISTRY_JUSTIFICATIONS)) {
    if (key.toLowerCase().trim() === normalizedName) {
      return values;
    }
  }

  // Try matching by extracting "MD ..." part from ministry name
  // This handles cases like "Alic MD Media" matching "MD Media"
  const mdMatch = ministryName.match(/MD\s+.+/i);
  if (mdMatch) {
    const mdPart = mdMatch[0];
    for (const [key, values] of Object.entries(MINISTRY_JUSTIFICATIONS)) {
      if (key.toLowerCase().trim() === mdPart.toLowerCase().trim()) {
        return values;
      }
    }
  }

  // Try partial match - check if ministry name contains any key
  for (const [key, values] of Object.entries(MINISTRY_JUSTIFICATIONS)) {
    if (normalizedName.includes(key.toLowerCase())) {
      return values;
    }
  }

  // Return empty array if no match (will only show "Other" option)
  return [];
}

/**
 * Check if a ministry has predefined justifications
 */
export function ministryHasJustifications(ministryName: string): boolean {
  return getJustificationsForMinistry(ministryName).length > 0;
}
