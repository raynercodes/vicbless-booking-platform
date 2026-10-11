// Vic's dashboard data layer. The admin screens import from HERE and never know which layer answers.
// real -> realAdminApi.js (the backend, production builds); mock -> mockAdminApi.js (npm run dev and tests).
// See ../lib/mode.js for how the choice is made.

import { API_MODE } from '../lib/mode.js'
import * as mock from './mockAdminApi.js'
import * as real from './realAdminApi.js'

const layer = API_MODE === 'real' ? real : mock

export const isSignedIn = () => layer.isSignedIn()
export const signIn = (password) => layer.signIn(password)
export const signOut = () => layer.signOut()
export const getDay = (dateKey) => layer.getDay(dateKey)
export const cancelBooking = (item) => layer.cancelBooking(item)
export const moveBooking = (item, to) => layer.moveBooking(item, to)
export const addBlock = (block) => layer.addBlock(block)
export const removeBlock = (id) => layer.removeBlock(id)
export { SIGNED_OUT_EVENT } from './realAdminApi.js'
