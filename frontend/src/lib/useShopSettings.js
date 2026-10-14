import { useEffect, useSyncExternalStore } from 'react'
import { getShopSettings } from './api.js'
import { getShopSettingsNow, loadShopSettings, subscribeShopSettings } from './shopSettings.js'

// The shop's services and appointment lengths, for any screen. Starts with the shop's starting values, loads Vic's
// real ones once, and updates every screen using it when they change (for example after he saves in the dashboard).
export function useShopSettings() {
  const settings = useSyncExternalStore(subscribeShopSettings, getShopSettingsNow, getShopSettingsNow)
  useEffect(() => {
    loadShopSettings(getShopSettings)
  }, [])
  return settings
}
