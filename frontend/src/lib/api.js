// The customer-facing data layer. The pages import from HERE and never know which layer answers.
//
//   real  -> realApi.js, the backend (production builds)
//   mock  -> mockApi.js, fake data kept in the browser (npm run dev and the tests)
//
// See mode.js for how the choice is made. Both layers export the same functions with the same shapes.

import * as mock from './mockApi.js'
import { API_MODE } from './mode.js'
import * as real from './realApi.js'

const layer = API_MODE === 'real' ? real : mock

export { SlotTakenError } from './errors.js'
export const getAvailability = (dateKeys) => layer.getAvailability(dateKeys)
export const getBusy = (dateKeys) => layer.getBusy(dateKeys)
export const getShopSettings = () => layer.getShopSettings()
export const createBooking = (payload) => layer.createBooking(payload)
