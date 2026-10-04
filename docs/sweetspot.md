# Sweet-spot prediction

Sweet-spot predictions are planning estimates, not medical advice or a claim that an infant should sleep on a fixed schedule. The authoritative input is the family's recorded sleep diary. The model never edits those records; it derives eligible wake-to-next-sleep observations in `platform/backend/internal/sweetspot`.

## Why the model is structured this way

Parent diaries are useful for sleep onset and offset timing, but they tend to overestimate sleep and substantially undercount night wakings compared with actigraphy. A 314-infant comparison found the best diary/actigraphy agreement for onset and offset timing, generally within 30 minutes, while night-waking measures agreed less well. Other diary-validation studies reach the same practical conclusion: use recorded boundaries, but do not pretend every quiet waking was observed.

Infant sleep is governed by interacting homeostatic and circadian processes, with wide normal variation and rapid maturation. Circadian organization begins emerging in early infancy, but evidence does not establish precise universal “wake windows”; the American Academy of Sleep Medicine did not issue a duration recommendation for infants under four months because the evidence was insufficient. Accordingly, age ranges are only a low-confidence cold-start prior. Personal observations take over once enough history exists.

Nighttime awakenings and resettling are modeled separately from daytime wake periods. Videosomnography research distinguishes quiet self-soothing from signaling awakenings and shows that many awakenings are invisible to caregivers. A short recorded night gap can therefore be a genuine feed or resettling period, while a multi-hour gap can mean morning or a missed entry. The model preserves both possibilities and returns a wider interval when the personal distribution is uncertain.

Primary sources:

- [Diary and actigraphy agreement in 314 six-month-old infants](https://pmc.ncbi.nlm.nih.gov/articles/PMC8033447/)
- [Sleep diary versus actigraphy in infants](https://pmc.ncbi.nlm.nih.gov/articles/PMC4325935/)
- [Normal sleep patterns in infants and children: systematic review](https://pubmed.ncbi.nlm.nih.gov/21784676/)
- [Development of sleep–wake rhythms in Finnish birth cohorts](https://pubmed.ncbi.nlm.nih.gov/31583748/)
- [AASM pediatric sleep-duration consensus methodology](https://aasm.org/resources/pdf/pediatricsleepdurationmethods.pdf)
- [Videosomnography of infant self-soothing](https://pmc.ncbi.nlm.nih.gov/articles/PMC1201415/)
- [Infant signaling and self-soothing review](https://pmc.ncbi.nlm.nih.gov/articles/PMC10104392/)
- [Physiological modelling of infant sleep regulation](https://pmc.ncbi.nlm.nih.gov/articles/PMC11527290/)

## Algorithm version 4

The model reads only presented diary entries whose end a caregiver recorded, so an end the server derived ("the next sleep started") never becomes training data.

**Day structure.** Sleeps starting between 18:00 and 04:00 begin a night; the night continues through wakings of at most three hours that resume before 06:00. Its last segment is the morning wake when it ends between 04:00 and 12:00. Every other sleep is a nap, numbered from the morning. Each wake period is therefore a nighttime resettle, the first wake window of the day, or the window after nap *n*. While a sleep has just ended, a night segment ending at least 45 minutes before the child's usual morning (median of the last 14 mornings) is treated as a resettle. The structure also yields the median nap count of the last five complete days and flags a nap transition when it differs from the nine days before.

**Samples.** Earlier wake periods of the same kind (night or day) are weighted by recency (28-day half-life, 112-day horizon), by clock-time similarity (180-minute Gaussian), by similarity of the preceding sleep's length, by learned context, and by nap number (a different nap number halves the weight). Clock time carries the circadian signal; the nap number refines it once days are structured.

**Centre.** In log-minutes, gross outliers (beyond three robust deviations, typically a missed entry) are dropped. With at least a week of age spread and eight effective observations, a weighted linear trend in age is fitted and the centre is the weighted median of the detrended values at the current age, so a growing child is not predicted from its younger self. That centre is combined with the age prior by precision: the observed spread is pooled with the prior's over three pseudo-observations, so a few near-identical days cannot claim certainty, and the prior's influence fades with evidence instead of being kept at a fixed share. There is no hard age cap.

**Range.** The 10% and 90% quantiles of the fit's residuals, blended with the prior's spread while the effective sample size is small, inflated by the finite-sample factor and a calibration constant set from backtests, give an 80% range (`Coverage` 0.8). Confidence reflects the measured width and effective sample size.

**Age prior.** An 80% band of typical wake windows from birth (30-70 minutes) to four years (330-480 minutes), interpolated geometrically by age in days, so there are no month-boundary jumps. Nighttime resettles use 15-120 minutes. These are low-confidence starting points, not recommendations.

**Wake estimates.** For an ongoing night, the estimate is the morning wake as a clock time from the last 28 mornings, moving later while the night continues. For a nap, it is the recent distribution of naps with the same number, conditioned on the child still being asleep.

## Evaluation results

`evaluate-sweetspot` compares the live model with the frozen version 3 (`cmd/evaluate-sweetspot/v3`), the age prior alone, "same as the last comparable window", and a 14-day personal median, on events every model can predict. On one family's real diary (392 sleeps, birth to 4 months, 336 next-sleep events):

| | v3 | v4 |
| --- | --- | --- |
| next sleep, mean absolute error | 46.8 min | 45.8 min |
| next sleep within 15 / 30 min | 35% / 56% | 42% / 60% |
| next sleep pinball loss | 21.4 | 17.9 |
| range coverage, actual / claimed | 45% / 50% | 77% / 80% |
| nighttime resettle within 15 min | 46% | 60% |
| morning wake, mean absolute error | not modelled (266 min) | 44.5 min |
| nap end, mean absolute error, coverage | 34.3 min, 52% / 50% | 32.8 min, 81% / 80% |

The calibration constants (1.3 for wake windows, 1.05 for nap ends) were set on this diary, which covers only early infancy, when schedules are least regular; ranges are correspondingly wide. Nap numbering and the age trend made little difference at this age and are expected to matter more from about six months, when days consolidate. Re-run the backtest on more diaries, especially older children, before trusting the constants beyond infancy.

## Optional context

Sleep sessions can record `wake_mood` (`calm`, `fussy`, `crying`), `wake_reason` (`natural`, `feed`, `discomfort`, `caregiver`), whether a caregiver intervened, sleep location, and free-form imported start/end conditions. These fields are optional. A context value is not allowed to affect weighting until the child has at least five observations of it; this prevents a single unusual night from moving the estimate.

The most useful low-friction questions at wake time are “How did they wake?” and “Why did they wake?”. Crying should not be interpreted as a universal numerical correction: published associations vary with age and child, so Uneton learns only child-specific context effects.

## Evaluation

Run a chronological backtest with a Huckleberry export (`-csv`) or a plain `started_at,ended_at` CSV of RFC 3339 timestamps (`-sessions`):

```sh
go run ./platform/backend/cmd/evaluate-sweetspot \
  -sessions /path/to/sleeps.csv \
  -timezone Europe/Helsinki \
  -birth-date YYYY-MM-DD
```

Every estimate uses only records preceding the event being predicted. The command prints mean and median absolute error, within-15/30-minute rates, pinball loss, actual versus claimed range coverage and width, by clock phase and age band, plus wake-estimate accuracy for nights (against the morning wake) and naps; it never prints individual sleep records. Keep diaries used for evaluation outside the repository. This is validation against an imperfect diary, not clinical validation or a guarantee of generalization.
