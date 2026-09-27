# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users
Travellers who plan with the Plan-ish app (Android) and people curious about a
trip someone really made. Mostly on a phone, often in the evening, looking for
where to go next; some arrive from a link a friend shared.

## Product Purpose
The Plan-ish Community is where finished trips become itineraries other people
can use. The first job of the site is **discovering itineraries**: browse, open
one, see it day by day, like it, talk about it, and open it in the app to copy
it into one's own planning.

## Positioning
Itineraries that were actually travelled. The app records the trip; a published
itinerary says how much of it the GPS confirmed ("original"), whether it was
marked by hand ("feita"), or whether it is only a plan ("roteiro"). People who
copy an itinerary and make it themselves are counted ("feita por N").

## Operating Context
- Static site on GitHub Pages; data in Supabase (Postgres with row-level
  security). No build step.
- Reading needs no account. Liking, commenting and replying need a Community
  account (email link, no password). The app never signs in: it is "linked" to
  an account from `ligar.html`.
- Names are given by the Community from a list of playful names; nobody picks
  their own.

## Capabilities and Constraints
- Feed, itinerary page (days, stops, visit marks, likes, threaded comments one
  level deep, likes on comments, report), public traveller profile, account,
  sign-in, link the app.
- The site never shows prices or links to pay (Play policy for the app that
  links here). Paid membership is undecided.
- Personal data never published: no home, no GPS track, no participants.

## Brand Commitments
- Name: Plan-ish. Portuguese from Portugal, friendly and professional, never
  childish.
- Playful names ("Mochila Curiosa", "Farol Tranquilo") are part of the identity.

## Evidence on Hand
No real itineraries yet beyond the owner's tests. No testimonials, no user
counts, no press: do not invent any.

## Product Principles
1. The trip, not the person: nothing personal is ever shown.
2. Say how true it is: original, done or plan, always visible.
3. Reading is free and needs no account.
4. Conversation stays about the trip.
