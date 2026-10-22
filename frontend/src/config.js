// Everything business-specific lives here.
// Hours, services, address and social links are Vic's real ones. The phone number is still a PLACEHOLDER.

export const BUSINESS = {
  name: 'Vicbless Barbershop',
  // How customers reach Vic. The site shows this email wherever it used to show the phone number.
  email: 'vicslegacy89@gmail.com',
  phone: '(555) 010-0123', // PLACEHOLDER, not shown anywhere on the site right now
  address: ['656 S Main St, Suite C', 'Baxley, GA 31513'],
}

export const SOCIAL = {
  tiktok: 'https://www.tiktok.com/@vicblesss',
  instagram: 'https://www.instagram.com/vicblessss',
}

// Vic is the only staff for now. Add more entries later and the booking
// payload already carries a staffId, so the data model will not change.
export const STAFF = [{ id: 'vic', name: 'Vic' }]

// Opening windows per weekday, in minutes after midnight. 0 = Sunday.
// null = closed. A day can have several windows (Saturday has a break).
const at = (h, m = 0) => h * 60 + m

export const HOURS = {
  0: null, // Sunday: closed
  1: [[at(12), at(18)]], // Monday 12:00 pm to 6:00 pm
  2: [[at(12), at(18)]], // Tuesday 12:00 pm to 6:00 pm
  3: null, // Wednesday: closed
  4: [[at(11), at(19)]], // Thursday 11:00 am to 7:00 pm
  5: [[at(11), at(19)]], // Friday 11:00 am to 7:00 pm
  6: [
    [at(9), at(12)], // Saturday 9:00 am to 12:00 pm
    [at(12, 35), at(17)], // and 12:35 pm to 5:00 pm
  ],
}

// What Vic can change from his dashboard (Settings > Shop settings): the services with their prices, and how long
// an appointment is on each weekday. The real values live in the database; these are the shop's STARTING values.
// The site shows them until the API answers and keeps using them if it never does, and the backend starts from the
// same numbers (a backend test fails if the two ever differ).
//
// price is the starting price in whole dollars. from: true shows it as "$65+".
export const SERVICES = [
  { id: 'mens-cut', name: "Men's haircut", price: 55 },
  {
    id: 'mens-design',
    name: "Men's haircut with design",
    price: 65,
    from: true,
    note: 'Small or freestyle design',
  },
  {
    id: 'mens-beard-eyebrow',
    name: "Men's haircut with beard and eyebrow",
    price: 65,
    from: true,
    note: 'Includes free hot towel if requested and hair styling',
  },
  {
    id: 'buzz-beard',
    name: 'Head buzzed/shave and beard',
    price: 40,
    note: 'Same price for just beards. Tell Vic in person if you want it buzzed or shaved.',
  },
  {
    id: 'kids-design',
    name: 'Kids cut (12 and under) with design',
    price: 40,
    from: true,
    note: '$5 extra for a small design, $10 more for a bigger design',
  },
]

// After Hours Cuts: late appointments after the shop closes, one service that covers everything. It is not one of the
// services above: it can only be booked at the after-hours times, and those times can only be booked with it.
// Vic edits the price, the description and how many late appointments each weekday has (0 = Sunday) in Shop settings.
// The backend starts from the same values (a backend test fails if the two ever differ).
export const AFTER_HOURS = {
  id: 'after-hours',
  name: 'After Hours Cuts',
  price: 70,
  note: 'Late appointments after the shop closes. Any cut, design, beard or eyebrow work, all in one price.',
  slots: { 0: 0, 1: 0, 2: 0, 3: 0, 4: 2, 5: 2, 6: 0 }, // Thursday (4) and Friday (5): 2 late appointments each
}
export const MAX_AFTER_SLOTS = 6 // the most late appointments Vic can add to one day

// How long one appointment is on each weekday, in minutes (0 = Sunday). Every service takes one appointment.
// Monday and Tuesday are 45 minutes (Vic's request); the other days are 35. Vic can change any day in 5 minute steps.
export const SLOT_MINUTES_BY_DAY = { 0: 35, 1: 45, 2: 45, 3: 35, 4: 35, 5: 35, 6: 35 }
export const SLOT_MIN = 15 // the shortest appointment Vic can set
export const SLOT_MAX = 120 // the longest
export const SLOT_STEP = 5 // lengths go up in steps of this many minutes
export const MAX_SERVICES = 12
export const DAYS_AHEAD = 14

// Appointment reminders. Vic switches each of these on or off in Shop settings. The numbers are hours before the
// appointment; the backend accepts exactly these (a backend test checks). Reminders go out by email and, for customers
// who ticked the box below, by text.
export const REMINDER_CHOICES = [48, 24, 12, 6, 4, 3, 2, 1]
export const REMINDER_HOURS_DEFAULT = [24, 2]

// The tick box on the booking form. Left unticked until the customer ticks it (texting someone needs their yes).
// Texts are sent for the confirmation, the reminders and any change Vic makes to the appointment.
export const SMS_CONSENT = 'Text me my confirmation, reminders and any changes. Msg & data rates may apply. Reply STOP to opt out.'

// The branded call to action. Used on every booking button.
export const CTA_TEXT = 'Book here to get blessed'

// The photo section under the video: headline, paragraph, and the words stacked over the photo.
export const STATEMENT = {
  headline: "EVERY CUT ISN'T JUST A CUT. IT'S A BLESSING.",
  body: 'Consistent precision cuts with clean detail and a personalized cut experience to give you confidence and blessings.',
  words: ['Quality', 'Detail', 'Consistency', 'Baxley, GA'],
}

// Call to action in the middle of the photo section (exact wording from Vic).
export const STATEMENT_CTA = 'Book Here to get blessed'

// Small credit in the footer.
export const CREDIT = { text: 'Website By RaynerCodes Cloud Solutions', url: 'https://raynercodes.dev' }

// Big headline on the screen shown after a booking is confirmed (exact wording from Vic).
// Two lines; the second one is shown in the purple accent colour.
export const SUCCESS_HEADLINE = ['If you wanna get fresh..', 'Come to Vicbless']

// Words shown at the top of the home page video, right under the logo. A TEST for Vic.
// One entry per line. The last line is shown in the purple accent colour.
// To hide it, change the list to just an empty pair of brackets.
export const HOME_TAGLINE = ['If you wanna get fresh,', 'come to VicBless']

// The most a customer may type. The booking form enforces these and shows the notes counter; the API
// enforces the same numbers, and a backend test fails if the two ever differ.
export const LIMITS = { name: 50, notes: 500 }

// Which comes first on the home page, a TEST for Vic (change this one word to compare the two looks):
//   'photo-first'  the photo section (headline, paragraph, stacked words) is the first thing under the logo, then the video
//   'video-first'  the video first, then the photo section (how it was)
export const HOME_ORDER = 'photo-first'
