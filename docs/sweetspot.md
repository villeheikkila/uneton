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

## Algorithm version 3

For each completed sleep, the system considers the interval from its recorded end to the next recorded start. It rejects overlaps, gaps under five minutes, and gaps too long to distinguish from missing logging. It then:

1. Classifies the wake by local clock phase: nighttime resettling, morning, daytime, or bedtime.
2. Uses only earlier observations from the same phase, preventing nighttime feeds from distorting daytime nap estimates.
3. Weights observations by recency (28-day half-life), circular clock-time similarity, and preceding sleep duration.
4. Requires comparable observations on at least five separate local days before personal history can move the estimate. Multiple naps from one day do not count as repeated evidence.
5. Uses a weighted median as the personal target and weighted quartiles as the uncertainty range, with a minimum range width to avoid false precision.
6. Blends the personal distribution with an age-appropriate prior as repeated days accumulate, retaining at least 25% of the prior. Daytime predictions are constrained to that age range; overnight resettling remains separate because a recorded night gap is often an incomplete observation.
7. Falls back to a broad age-based estimate until five comparable days are available.

The 120-day history cap and recency weighting let the model follow rapid developmental change. Predictions are computed on demand from the server's current authoritative projection, so retries, offline commands, and reconnects do not create separate model state or conflict semantics. The version is returned with every estimate so evaluation can compare revisions without mixing their results.

## Optional context

Sleep sessions can record `wake_mood` (`calm`, `fussy`, `crying`), `wake_reason` (`natural`, `feed`, `discomfort`, `caregiver`), whether a caregiver intervened, sleep location, and free-form imported start/end conditions. These fields are optional. A context value is not allowed to affect weighting until the child has at least five observations of it; this prevents a single unusual night from moving the estimate.

The most useful low-friction questions at wake time are “How did they wake?” and “Why did they wake?”. Crying should not be interpreted as a universal numerical correction: published associations vary with age and child, so Uneton learns only child-specific context effects.

## Evaluation

Run a chronological backtest with:

```sh
go run ./platform/backend/cmd/evaluate-sweetspot \
  -csv /path/to/sleep-history.csv \
  -timezone Europe/Helsinki \
  -birth-date YYYY-MM-DD
```

Every estimate uses only records preceding the event being predicted. The command prints aggregate error, within-15/30-minute rates, interval coverage, phase breakdowns, and the latest estimate; it does not print individual sleep records. This is validation against an imperfect diary, not clinical validation or a guarantee of generalization.
