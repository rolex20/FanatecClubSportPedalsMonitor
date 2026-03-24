# Current coding style and culture in this repo

* This is a program I will maintain for years. It is written so that future me can understand it in one sitting.
* Notice the style in this program: beautiful, classic C — K\&R-style clarity, small purposeful functions, explicit state, simple control flow, excellent section comments, and no overengineering with careful systems code from a good technical book with a main() that reads like a table of contents.

## Style target:

* readable like The C Programming Language
* sturdy like Writing Solid C Code
* structured almost like literate programming from Donald Knuth, but still plain .c code, not CWEB
* comments should introduce sections and explain why on obscure constructs, not narrate every line

## Do what you love

* Linus Torvals basically said "I love doing that… optimized at the level where I worry about single instructions and especially single cache misses… To some degree people say you should not micro-optimize, but if what you love is micro-optimization, that's what you should do."
* This is why I love too, and this project is my baby and we are going to give it all the love, ok?

## Wanted Workflow from you

For this repo, use this workflow
0. I explain the task.  Depending on the task you create a plan/design if I ask for it or just continue to ask questions if any or comment.  When the discussion phase is completed go to next step.

1. create a new branch
2. implement the requested changes
3. stop and tell me when the code is ready for my review/edit
4. wait for me to finish my edits
5. then commit, push, and create the PR with gh
6. I will do the final merge myself in web GitHub
