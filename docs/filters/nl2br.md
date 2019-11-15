Filter `nl2br`
==============

The `nl2br` filter inserts HTML line breaks before all newlines in a string:

```twig
{{ "I like Twig.\nYou will like it too."|nl2br }}
{# outputs

    I like Twig.<br />
    You will like it too.

#}
```