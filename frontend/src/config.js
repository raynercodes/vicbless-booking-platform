// Everything business-specific lives here.
// Hours, services, address and social links are Vic's real ones. The phone number is still a PLACEHOLDER.

export const BUSINESS = {
  name: 'Vicbless Barbershop',
  phone: '(555) 010-0123', // PLACEHOLDER
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

// price is the starting price. from: true shows it as "$65+".
export const SERVICES = [
  { id: 'mens-cut', name: "Men's haircut", minutes: 35, price: 55 },
  {
    id: 'mens-design',
    name: "Men's haircut with design",
    minutes: 35,
    price: 65,
    from: true,
    note: 'Small or freestyle design',
  },
  {
    id: 'mens-beard-eyebrow',
    name: "Men's haircut with beard and eyebrow",
    minutes: 35,
    price: 65,
    from: true,
    note: 'Includes free hot towel if requested and hair styling',
  },
  {
    id: 'buzz-beard',
    name: 'Head buzzed/shave and beard',
    minutes: 30,
    price: 40,
    note: 'Same price for just beards. Tell Vic in person if you want it buzzed or shaved.',
  },
  {
    id: 'kids-design',
    name: 'Kids cut (12 and under) with design',
    minutes: 30,
    price: 40,
    from: true,
    note: '$5 extra for a small design, $10 more for a bigger design',
  },
]

// Vic books in 35 minute blocks (Saturday's 12:35 restart follows the same rhythm).
// Every service fits in one block, longer ones would take several.
export const SLOT_MINUTES = 35
export const DAYS_AHEAD = 14

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
