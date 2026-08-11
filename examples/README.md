# Examples

**example_property/** — a complete, runnable property registration: one
explicit room list, one generated tower layout, and one deliberately invalid
property (to show that a bad property can never take down the others).

To try it: copy `example_property/` into your server's `resources/` folder and
`ensure example_property`. It registers synthetic rooms at placeholder
coordinates — it is for development, not for a live server.

To make your own map rentable: copy these two files into your map resource,
keep the registration code as-is, and replace the property
payloads with your rooms. The full field reference is in the main README.
