import { describe, expect, it } from 'vitest'
import { NOTE_PREVIEW_CHARS, isLongNote } from './notes.js'

describe('isLongNote', () => {
  it('shows short notes in full', () => {
    expect(isLongNote('')).toBe(false)
    expect(isLongNote(undefined)).toBe(false)
    expect(isLongNote('Wants it shorter on the sides')).toBe(false)
    expect(isLongNote('a'.repeat(NOTE_PREVIEW_CHARS))).toBe(false)
  })

  it('folds a note one character over the preview size', () => {
    expect(isLongNote('a'.repeat(NOTE_PREVIEW_CHARS + 1))).toBe(true)
    expect(isLongNote('a'.repeat(500))).toBe(true)
  })

  it('folds a short note with many line breaks', () => {
    expect(isLongNote('one\ntwo\nthree')).toBe(false)
    expect(isLongNote('one\ntwo\nthree\nfour')).toBe(true)
  })
})
