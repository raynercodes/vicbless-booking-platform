import { beforeEach, describe, expect, it, vi } from 'vitest'
import {
  DAY_KEYS,
  DEFAULT_SHOP_SETTINGS,
  checkDraft,
  draftFrom,
  findService,
  fromApi,
  getShopSettingsNow,
  isChanged,
  loadShopSettings,
  newDraftService,
  resetShopSettings,
  setShopSettings,
  slotFor,
  subscribeShopSettings,
  toggleReminder,
  toApi,
} from './shopSettings.js'

const apiBody = () => toApi(DEFAULT_SHOP_SETTINGS)

describe('defaults', () => {
  it('start with Monday and Tuesday at 45 minutes and the rest at 35', () => {
    expect(DEFAULT_SHOP_SETTINGS.slotMinutes).toEqual({ 0: 35, 1: 45, 2: 45, 3: 35, 4: 35, 5: 35, 6: 35 })
    expect(DEFAULT_SHOP_SETTINGS.services).toHaveLength(5)
  })

  it('slotFor reads the length for the weekday of a date', () => {
    expect(slotFor(DEFAULT_SHOP_SETTINGS, new Date(2026, 9, 13))).toBe(45) // Tuesday
    expect(slotFor(DEFAULT_SHOP_SETTINGS, new Date(2026, 9, 15))).toBe(35) // Thursday
  })

  it('finds a service by id', () => {
    expect(findService(DEFAULT_SHOP_SETTINGS, 'mens-cut').price).toBe(55)
    expect(findService(DEFAULT_SHOP_SETTINGS, 'nope')).toBeNull()
  })
})

describe('reminders', () => {
  it('start at 24 and 2 hours before', () => {
    expect(DEFAULT_SHOP_SETTINGS.reminderHours).toEqual([24, 2])
    expect(apiBody().reminderHours).toEqual([24, 2])
  })

  it('an answer from before reminders existed keeps the starting ones', () => {
    const body = apiBody()
    delete body.reminderHours
    expect(fromApi(body).reminderHours).toEqual([24, 2])
  })

  it('sorts biggest first, and refuses times that are not on the list', () => {
    expect(fromApi({ ...apiBody(), reminderHours: [2, 12, 4] }).reminderHours).toEqual([12, 4, 2])
    expect(fromApi({ ...apiBody(), reminderHours: [] }).reminderHours).toEqual([])
    expect(fromApi({ ...apiBody(), reminderHours: [5] })).toBeNull()
    expect(fromApi({ ...apiBody(), reminderHours: 'soon' })).toBeNull()
  })

  it('can be switched on and off in a draft', () => {
    let d = draftFrom(DEFAULT_SHOP_SETTINGS)
    d = toggleReminder(d, 6)
    expect(d.reminders).toEqual([24, 6, 2])
    d = toggleReminder(toggleReminder(d, 24), 2)
    expect(d.reminders).toEqual([6])
    expect(checkDraft(d).settings.reminderHours).toEqual([6])
    expect(isChanged(d, DEFAULT_SHOP_SETTINGS)).toBe(true)
    expect(checkDraft(toggleReminder(d, 6)).settings.reminderHours).toEqual([]) // none at all is allowed
  })
})

describe('API shape', () => {
  it('round-trips', () => {
    expect(fromApi(apiBody())).toEqual(DEFAULT_SHOP_SETTINGS)
    expect(apiBody().slotMinutes).toEqual({ sun: 35, mon: 45, tue: 45, wed: 35, thu: 35, fri: 35, sat: 35 })
  })

  it('refuses anything malformed', () => {
    expect(fromApi(null)).toBeNull()
    expect(fromApi({ services: [], slotMinutes: apiBody().slotMinutes })).toBeNull()
    expect(fromApi({ ...apiBody(), slotMinutes: { ...apiBody().slotMinutes, mon: 47 } })).toBeNull()
    const noDay = { ...apiBody().slotMinutes }
    delete noDay.fri
    expect(fromApi({ ...apiBody(), slotMinutes: noDay })).toBeNull()
    expect(fromApi({ ...apiBody(), services: [{ id: 'x', name: 'X', price: '5' }] })).toBeNull()
  })

  it('leaves the id off a new service', () => {
    const s = { services: [{ id: '', name: 'Shave', price: 20, from: false, note: '' }], slotMinutes: DEFAULT_SHOP_SETTINGS.slotMinutes }
    expect(toApi(s).services[0]).toEqual({ name: 'Shave', price: 20, from: false, note: '' })
  })

  it('uses the weekday names the API expects', () => {
    expect(DAY_KEYS).toEqual(['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'])
  })
})

describe('checkDraft', () => {
  const fresh = () => draftFrom(DEFAULT_SHOP_SETTINGS)

  it('accepts the starting settings unchanged', () => {
    const r = checkDraft(fresh())
    expect(r.ok).toBe(true)
    expect(r.settings).toEqual(DEFAULT_SHOP_SETTINGS)
  })

  it('turns typed text into numbers and tidies names', () => {
    const d = fresh()
    d.services[0].name = '  Fresh   cut '
    d.services[0].price = '60'
    d.slots[4] = '25'
    const r = checkDraft(d)
    expect(r.settings.services[0]).toMatchObject({ id: 'mens-cut', name: 'Fresh cut', price: 60 })
    expect(r.settings.slotMinutes[4]).toBe(25)
  })

  it.each([['14'], ['17'], ['125'], ['abc'], ['']])('refuses the length %j', (text) => {
    const d = fresh()
    d.slots[1] = text
    const r = checkDraft(d)
    expect(r.ok).toBe(false)
    expect(r.errors.slots[1]).toMatch(/15 to 120 minutes, in steps of 5/)
  })

  it.each([['-1'], ['1000'], ['12.5'], [''], ['abc']])('refuses the price %j', (text) => {
    const d = fresh()
    d.services[2].price = text
    expect(checkDraft(d).errors.services[d.services[2].key].price).toBeTruthy()
  })

  it('refuses a missing, too short or duplicate name', () => {
    const d = fresh()
    d.services[0].name = 'x'
    d.services[3].name = "MEN'S haircut with DESIGN" // same as the second service, apart from capitals
    d.services[2].name = ''
    const { errors } = checkDraft(d)
    expect(errors.services[d.services[0].key].name).toBeTruthy()
    expect(errors.services[d.services[3].key].name).toMatch(/already has this name/)
    expect(errors.services[d.services[2].key].name).toBeTruthy()
  })

  it('refuses a long note, no services and too many services', () => {
    const d = fresh()
    d.services[0].note = 'n'.repeat(121)
    expect(checkDraft(d).errors.services[d.services[0].key].note).toBeTruthy()
    expect(checkDraft({ ...fresh(), services: [] }).errors.general).toMatch(/between 1 and 12/)
    const many = fresh()
    while (many.services.length < 13) many.services.push({ ...newDraftService(), name: `Service ${many.services.length}`, price: '5' })
    expect(checkDraft(many).errors.general).toMatch(/between 1 and 12/)
  })

  it('gives each new row its own key and no id', () => {
    const a = newDraftService()
    const b = newDraftService()
    expect(a.key).not.toBe(b.key)
    expect(a.id).toBe('')
  })

  it('notices a change', () => {
    const d = fresh()
    expect(isChanged(d, DEFAULT_SHOP_SETTINGS)).toBe(false)
    d.slots[0] = '40'
    expect(isChanged(d, DEFAULT_SHOP_SETTINGS)).toBe(true)
  })
})

describe('the shared store', () => {
  beforeEach(() => resetShopSettings())

  it('starts with the defaults and tells listeners about changes', () => {
    const heard = vi.fn()
    const off = subscribeShopSettings(heard)
    expect(getShopSettingsNow()).toBe(DEFAULT_SHOP_SETTINGS)
    const next = { ...DEFAULT_SHOP_SETTINGS, slotMinutes: { ...DEFAULT_SHOP_SETTINGS.slotMinutes, 3: 40 } }
    setShopSettings(next)
    expect(heard).toHaveBeenCalledTimes(1)
    expect(getShopSettingsNow().slotMinutes[3]).toBe(40)
    off()
    setShopSettings(DEFAULT_SHOP_SETTINGS)
    expect(heard).toHaveBeenCalledTimes(1)
  })

  it('loads once and keeps the defaults if the API fails or sends nonsense', async () => {
    const fetcher = vi.fn().mockRejectedValue(new Error('offline'))
    await loadShopSettings(fetcher)
    await loadShopSettings(fetcher)
    expect(fetcher).toHaveBeenCalledTimes(1)
    expect(getShopSettingsNow()).toBe(DEFAULT_SHOP_SETTINGS)
    resetShopSettings()
    await loadShopSettings(() => ({ nonsense: true }))
    expect(getShopSettingsNow()).toBe(DEFAULT_SHOP_SETTINGS)
  })

  it('uses what the API sends', async () => {
    const body = apiBody()
    body.slotMinutes.mon = 30
    await loadShopSettings(() => body)
    expect(getShopSettingsNow().slotMinutes[1]).toBe(30)
  })
})

describe('paying online', () => {
  beforeEach(() => resetShopSettings())

  it('is off until the API says it is set up', () => {
    expect(DEFAULT_SHOP_SETTINGS.payOnline).not.toBe(true) // card payment is offered only once the API says it is set up
    expect(fromApi({ ...apiBody(), payOnline: true }).payOnline).toBe(true)
    expect(fromApi({ ...apiBody(), payOnline: 'yes' }).payOnline).toBe(false) // only a real true counts
    expect(fromApi(apiBody())).not.toHaveProperty('payOnline') // Vic's own settings do not carry it
  })

  it('is never sent back when Vic saves his settings', () => {
    expect(toApi({ ...DEFAULT_SHOP_SETTINGS, payOnline: true })).not.toHaveProperty('payOnline')
  })

  it('survives Vic saving his settings, which come back without it', async () => {
    await loadShopSettings(() => ({ ...apiBody(), payOnline: true }))
    expect(getShopSettingsNow().payOnline).toBe(true)
    setShopSettings(fromApi(apiBody()))
    expect(getShopSettingsNow().payOnline).toBe(true)
  })
})
