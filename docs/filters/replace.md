---
layout: page
title: Filters › replace
---

[← filters](./../filters.md)

<!-- {% raw %} -->

Filter `replace(from)`:
* from: The placeholder values

---

The replace filter formats a given string by replacing the placeholders (placeholders are free-form):

```twig
{{ "I like %this% and %that%."|replace({'%this%': foo, '%that%': "bar"}) }}

{# outputs I like foo and bar
   if the foo parameter equals to the foo string. #}

{# using % as a delimiter is purely conventional and optional #}

{{ "I like this and --that--."|replace({'this': foo, '--that--': "bar"}) }}

{# outputs I like foo and bar #}
```

<!-- {% endraw %} -->