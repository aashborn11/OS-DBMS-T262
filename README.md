# Guild Press (College PBL Version)

A small version of the Guild Press platform: students design apparel, submit it for review, and approved designs go on sale in a storefront. The designer earns compensation on each sale.

**Course project:** DBMS + OS (Project-Based Learning), Graphic Era (Deemed to be University)
**Team:** [FILL IN: 3 member names and roll numbers]


## 1. Problem Statement
Students have creative designs but no easy way to print, sell and earn from them. Printing needs inventory and money up front. Guild Press removes that barrier: a design is only printed when someone buys it (print on demand), and the designer is paid a share of the sale.

## 2. What the Project Does
1. A user creates a profile.
2. They create a design in two ways:
   - **In the studio:** pick a garment and colour, then build the artwork. The design is stored as a small JSON spec and drawn as SVG when displayed, so no image hosting is needed.
   - **By upload:** place an existing image on the t-shirt.
3. The design goes into a review queue (the Press Room).
4. A reviewer approves or rejects it.
5. Approved designs appear in the Gallery, where they can be liked and bought.
6. Each sale updates the designer's earnings in the Compensation ledger.

## 3. Main Screens
| Screen | Purpose |
|---|---|
| Gallery | Storefront with filters, sorting, likes and checkout |
| Design Studio | Garment, colour and artwork picker with live preview |
| Designers | Roster and public profiles of designers |
| Compensation | Guild totals and a payout ledger per designer |
| Press Room | Review queue where designs are approved or rejected |

## 4. Technology
- Single-file frontend (HTML, CSS, JavaScript), no build step, no CDN, so it runs by opening the file.
- Designs stored as JSON and rendered to SVG.
- Data layer: [FILL IN: localStorage / JSON file / SQL database]
- Backend: [FILL IN, or "none"]

## 5. DBMS Concepts Used
[FILL IN with what your code really does. Examples to check against it:]
- Entities and relationships: Users/Designers, Designs, Orders, Compensation, Reviews, Likes.
- ER diagram: see `docs/er-diagram.png` [ADD]
- Tables, primary keys, foreign keys, and constraints (for example a design must belong to a designer).
- Normalisation: [FILL IN, for example 3NF]
- Queries: sorting and filtering the gallery, total earnings per designer, designer ranking.
- Transactions: recording a sale and updating the designer's earnings together. [Only list this if you implemented it.]

## 6. OS Concepts Used
[FILL IN with what your code really does. Do not list a concept you did not implement.]
- Concept 1: [for example, how review requests are queued and picked up in order]
- Concept 2: [for example, scheduling or fair sharing of print jobs]
- Where in the code: `[file name]`

## 7. Compensation Logic
Designers earn a percentage of each sale. The rate rises as their number of sales grows. [FILL IN the percentages and tier thresholds used in this PBL version.]

## 8. How to Run
1. Download or clone the repository.
2. Open `index.html` in a browser. [Change if your steps differ.]
3. Demo flow: create a design in the studio, submit it, approve it in the Press Room, then find it in the Gallery.

## 9. Screenshots
[ADD 4–5 screenshots: Gallery, Studio, Press Room, Compensation, Designer profile]

## 10. Limitations
- This is a college-scale version. Payments and printing are simulated, not connected to real providers.
- [FILL IN anything else, such as no real login security]

## 11. Future Work
The full Guild Press is a separate, larger project with real accounts, a secure admin area, online payments and automatic print-on-demand fulfilment.

## 12. Team Contributions
| Member | Part |
|---|---|
| [Name] | [DBMS part] |
| [Name] | [OS part] |
| [Name] | [Frontend / studio] |

## 13. References
[FILL IN: textbooks, documentation, tutorials used]
