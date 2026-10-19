// Members 1, 2, and 3: submit and review designs, record sales, and process print jobs.

#include <sqlite3.h>

#include <ctime>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

using namespace std;

bool runSql(sqlite3* db, const string& sql) {
    char* error = nullptr;
    int result = sqlite3_exec(db, sql.c_str(), nullptr, nullptr, &error);
    if (result != SQLITE_OK) {
        cout << "Database error: " << (error ? error : "unknown error") << "\n";
        sqlite3_free(error);
        return false;
    }
    return true;
}

bool loadSchema(sqlite3* db) {
    ifstream file("schema.sql");
    if (!file) {
        cout << "Could not open schema.sql. Run the program from its folder.\n";
        return false;
    }
    stringstream contents;
    contents << file.rdbuf();
    return runSql(db, contents.str());
}

void addSampleData(sqlite3* db) {
    runSql(db,
        "INSERT OR IGNORE INTO designers(id, name) VALUES(1, 'Asha');"
        "INSERT OR IGNORE INTO reviewers(id, name) VALUES(1, 'Ravi');"
        "INSERT OR IGNORE INTO designs(id, designer_id, title, status) "
        "VALUES(1, 1, 'Campus Cat', 'approved');"
        "INSERT OR IGNORE INTO review_history "
        "(design_id, reviewer_id, decision, note, reviewed_at) "
        "VALUES(1, 1, 'approved', 'Sample approved design', unixepoch());"
    );
}

void submitDesign(sqlite3* db, const string& title) {
    sqlite3_stmt* statement = nullptr;
    const char* sql =
        "INSERT INTO designs(designer_id, title, status) VALUES(1, ?, 'pending');";
    if (sqlite3_prepare_v2(db, sql, -1, &statement, nullptr) == SQLITE_OK) {
        sqlite3_bind_text(statement, 1, title.c_str(), -1, SQLITE_TRANSIENT);
        if (sqlite3_step(statement) == SQLITE_DONE)
            cout << "Design submitted for review. Design ID: "
                 << sqlite3_last_insert_rowid(db) << "\n";
        else
            cout << "Could not submit the design.\n";
    } else {
        cout << "Could not prepare the design submission.\n";
    }
    sqlite3_finalize(statement);
}

void reviewPendingDesign(sqlite3* db) {
    sqlite3_stmt* statement = nullptr;
    const char* listSql =
        "SELECT id, title FROM designs WHERE status='pending' ORDER BY id;";
    if (sqlite3_prepare_v2(db, listSql, -1, &statement, nullptr) != SQLITE_OK) {
        cout << "Could not read pending designs.\n";
        return;
    }

    cout << "\nPending designs\n";
    bool found = false;
    while (sqlite3_step(statement) == SQLITE_ROW) {
        found = true;
        cout << sqlite3_column_int(statement, 0) << ". "
             << sqlite3_column_text(statement, 1) << "\n";
    }
    sqlite3_finalize(statement);
    if (!found) {
        cout << "No designs are waiting for review.\n";
        return;
    }

    string input;
    cout << "Design ID to review: ";
    getline(cin, input);
    long long designId = 0;
    istringstream idInput(input);
    if (!(idInput >> designId) || designId <= 0) {
        cout << "Enter a valid design ID.\n";
        return;
    }

    string choice;
    cout << "Approve or reject? (a/r): ";
    getline(cin, choice);
    if (choice != "a" && choice != "A" && choice != "r" && choice != "R") {
        cout << "Enter a or r.\n";
        return;
    }
    string decision = (choice == "a" || choice == "A") ? "approved" : "rejected";
    string note;
    cout << "Review note: ";
    getline(cin, note);

    if (!runSql(db, "BEGIN IMMEDIATE;")) return;
    bool ok = false;
    statement = nullptr;
    const char* updateSql = "UPDATE designs SET status=? WHERE id=? AND status='pending';";
    if (sqlite3_prepare_v2(db, updateSql, -1, &statement, nullptr) == SQLITE_OK) {
        sqlite3_bind_text(statement, 1, decision.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(statement, 2, designId);
        ok = sqlite3_step(statement) == SQLITE_DONE && sqlite3_changes(db) == 1;
    }
    sqlite3_finalize(statement);

    if (ok) {
        const char* historySql =
            "INSERT INTO review_history(design_id, reviewer_id, decision, note, reviewed_at) "
            "VALUES(?, 1, ?, ?, unixepoch());";
        if (sqlite3_prepare_v2(db, historySql, -1, &statement, nullptr) == SQLITE_OK) {
            sqlite3_bind_int64(statement, 1, designId);
            sqlite3_bind_text(statement, 2, decision.c_str(), -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 3, note.c_str(), -1, SQLITE_TRANSIENT);
            ok = sqlite3_step(statement) == SQLITE_DONE;
        } else {
            ok = false;
        }
        sqlite3_finalize(statement);
    }

    if (ok) ok = runSql(db, "COMMIT;");
    else runSql(db, "ROLLBACK;");
    if (ok) cout << "Design " << decision << ". Review was saved.\n";
    else cout << "Review failed. The design status was not changed.\n";
}

void showReviewHistory(sqlite3* db) {
    sqlite3_stmt* statement = nullptr;
    const char* sql =
        "SELECT designs.id, designs.title, reviewers.name, review_history.decision, "
        "review_history.note FROM review_history "
        "JOIN designs ON designs.id=review_history.design_id "
        "JOIN reviewers ON reviewers.id=review_history.reviewer_id "
        "ORDER BY review_history.id;";
    if (sqlite3_prepare_v2(db, sql, -1, &statement, nullptr) != SQLITE_OK) {
        cout << "Could not read review history.\n";
        return;
    }
    cout << "\nDesign | Title | Reviewer | Decision | Note\n";
    while (sqlite3_step(statement) == SQLITE_ROW) {
        cout << sqlite3_column_int(statement, 0) << " | "
             << sqlite3_column_text(statement, 1) << " | "
             << sqlite3_column_text(statement, 2) << " | "
             << sqlite3_column_text(statement, 3) << " | "
             << sqlite3_column_text(statement, 4) << "\n";
    }
    sqlite3_finalize(statement);
}

bool chooseApprovedDesign(sqlite3* db, long long& designId) {
    sqlite3_stmt* statement = nullptr;
    const char* sql =
        "SELECT designs.id, designs.title, designers.name FROM designs "
        "JOIN designers ON designers.id=designs.designer_id "
        "WHERE designs.status='approved' ORDER BY designs.id;";
    if (sqlite3_prepare_v2(db, sql, -1, &statement, nullptr) != SQLITE_OK) {
        cout << "Could not read approved designs.\n";
        return false;
    }

    cout << "\nApproved designs\n";
    bool found = false;
    while (sqlite3_step(statement) == SQLITE_ROW) {
        found = true;
        cout << sqlite3_column_int(statement, 0) << ". "
             << sqlite3_column_text(statement, 1) << " by "
             << sqlite3_column_text(statement, 2) << "\n";
    }
    sqlite3_finalize(statement);
    if (!found) {
        cout << "No approved designs are available.\n";
        return false;
    }

    string input;
    cout << "Design ID to buy: ";
    getline(cin, input);
    istringstream idInput(input);
    if (!(idInput >> designId) || designId <= 0) {
        cout << "Enter a valid design ID.\n";
        return false;
    }
    return true;
}

bool recordSale(sqlite3* db, long long designId, const string& customer, bool showFailure) {
    const double shirtPrice = 500.0;
    const double designerShare = 0.20;
    if (!runSql(db, "BEGIN;")) return false;

    sqlite3_stmt* statement = nullptr;
    const char* orderSql =
        "INSERT INTO orders(design_id, customer_name, amount, created_at) "
        "SELECT ?, ?, ?, unixepoch() FROM designs "
        "WHERE id=? AND status='approved';";
    bool ok = sqlite3_prepare_v2(db, orderSql, -1, &statement, nullptr) == SQLITE_OK;
    if (ok) {
        sqlite3_bind_int64(statement, 1, designId);
        sqlite3_bind_text(statement, 2, customer.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_double(statement, 3, shirtPrice);
        sqlite3_bind_int64(statement, 4, designId);
        ok = sqlite3_step(statement) == SQLITE_DONE;
    }
    sqlite3_finalize(statement);
    if (ok && sqlite3_changes(db) == 0) {
        cout << "Sale stopped: that design is not approved.\n";
        ok = false;
    }

    long long orderId = sqlite3_last_insert_rowid(db);
    if (ok) {
        const char* payoutSql =
            "INSERT INTO payouts(order_id, designer_id, amount) "
            "SELECT ?, designer_id, ? * ? FROM designs WHERE id=?;";
        ok = sqlite3_prepare_v2(db, payoutSql, -1, &statement, nullptr) == SQLITE_OK;
        if (ok) {
            sqlite3_bind_int64(statement, 1, orderId);
            sqlite3_bind_double(statement, 2, shirtPrice);
            sqlite3_bind_double(statement, 3, designerShare);
            sqlite3_bind_int64(statement, 4, designId);
            ok = sqlite3_step(statement) == SQLITE_DONE && sqlite3_changes(db) == 1;
        }
        sqlite3_finalize(statement);
    }

    if (ok) {
        const char* jobSql =
            "INSERT INTO print_jobs(order_id, designer_id, priority, created_at) "
            "SELECT ?, designer_id, ?, unixepoch() FROM designs WHERE id=?;";
        ok = sqlite3_prepare_v2(db, jobSql, -1, &statement, nullptr) == SQLITE_OK;
        if (ok) {
            sqlite3_bind_int64(statement, 1, orderId);
            sqlite3_bind_int(statement, 2, showFailure ? 9 : 3);
            sqlite3_bind_int64(statement, 3, designId);
            ok = sqlite3_step(statement) == SQLITE_DONE && sqlite3_changes(db) == 1;
        }
        sqlite3_finalize(statement);
    }

    if (ok) {
        ok = runSql(db, "COMMIT;");
        if (ok)
            cout << "Sale saved: Rs. " << shirtPrice << " order, Rs. "
                 << shirtPrice * designerShare << " designer payout, and print job created.\n";
    } else {
        runSql(db, "ROLLBACK;");
        if (showFailure) cout << "Transaction rolled back; no sale records were saved.\n";
    }
    return ok;
}

bool recoverExpiredJobs(sqlite3* db) {
    if (!runSql(db, "BEGIN IMMEDIATE;")) return false;
    bool ok = runSql(db,
        "UPDATE print_jobs SET status='queued', worker=NULL, lease_until=0 "
        "WHERE status='claimed' AND lease_until <= unixepoch();");
    int recovered = sqlite3_changes(db);
    if (ok) ok = runSql(db, "COMMIT;");
    else runSql(db, "ROLLBACK;");
    if (ok) cout << "Expired jobs returned to queue: " << recovered << "\n";
    return ok;
}

bool claimNextJob(sqlite3* db, const string& worker, long long& jobId) {
    if (!runSql(db, "BEGIN IMMEDIATE;")) return false;

    bool ok = runSql(db,
        "UPDATE print_jobs SET status='queued', worker=NULL, lease_until=0 "
        "WHERE status='claimed' AND lease_until <= unixepoch();");

    sqlite3_stmt* statement = nullptr;
    const char* selectSql =
        "SELECT id FROM print_jobs WHERE status='queued' "
        "ORDER BY priority - (SELECT COUNT(*) FROM print_jobs recent "
        "WHERE recent.designer_id=print_jobs.designer_id "
        "AND recent.status='completed' AND recent.created_at >= unixepoch()-60) DESC, "
        "created_at ASC LIMIT 1;";
    if (ok && sqlite3_prepare_v2(db, selectSql, -1, &statement, nullptr) == SQLITE_OK) {
        if (sqlite3_step(statement) == SQLITE_ROW) jobId = sqlite3_column_int64(statement, 0);
        else jobId = 0;
    } else {
        ok = false;
    }
    sqlite3_finalize(statement);

    if (ok && jobId != 0) {
        sqlite3_stmt* update = nullptr;
        const char* updateSql =
            "UPDATE print_jobs SET status='claimed', worker=?, lease_until=unixepoch()+30 "
            "WHERE id=? AND status='queued';";
        if (sqlite3_prepare_v2(db, updateSql, -1, &update, nullptr) == SQLITE_OK) {
            sqlite3_bind_text(update, 1, worker.c_str(), -1, SQLITE_TRANSIENT);
            sqlite3_bind_int64(update, 2, jobId);
            ok = sqlite3_step(update) == SQLITE_DONE && sqlite3_changes(db) == 1;
        } else {
            ok = false;
        }
        sqlite3_finalize(update);
    }

    if (ok) ok = runSql(db, "COMMIT;");
    else runSql(db, "ROLLBACK;");

    if (ok && jobId == 0) cout << "No queued print jobs.\n";
    return ok && jobId != 0;
}

void processNextJob(sqlite3* db) {
    string worker;
    cout << "Worker name: ";
    getline(cin, worker);
    if (worker.empty()) worker = "worker-1";

    long long jobId = 0;
    if (!claimNextJob(db, worker, jobId)) return;
    cout << "Worker " << worker << " claimed job " << jobId << ". Sending to simulated printer...\n";

    sqlite3_stmt* statement = nullptr;
    const char* updateSql =
        "UPDATE print_jobs SET status='completed', worker=NULL, lease_until=0 "
        "WHERE id=? AND status='claimed' AND worker=?;";
    if (sqlite3_prepare_v2(db, updateSql, -1, &statement, nullptr) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, jobId);
        sqlite3_bind_text(statement, 2, worker.c_str(), -1, SQLITE_TRANSIENT);
        if (sqlite3_step(statement) == SQLITE_DONE && sqlite3_changes(db) == 1)
            cout << "Job " << jobId << " completed.\n";
        else
            cout << "Could not complete the job; its lease will allow a retry.\n";
    } else {
        cout << "Could not prepare job completion.\n";
    }
    sqlite3_finalize(statement);
}

void simulateWorkerCrash(sqlite3* db) {
    long long jobId = 0;
    if (!claimNextJob(db, "crashed-worker", jobId)) return;

    sqlite3_stmt* statement = nullptr;
    const char* sql = "UPDATE print_jobs SET lease_until=unixepoch()-1 "
                      "WHERE id=? AND status='claimed';";
    if (sqlite3_prepare_v2(db, sql, -1, &statement, nullptr) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, jobId);
        if (sqlite3_step(statement) == SQLITE_DONE)
            cout << "Worker stopped while handling job " << jobId
                 << ". Its lease is expired; choose recovery to requeue it.\n";
        else
            cout << "Could not simulate the worker stopping.\n";
    } else {
        cout << "Could not prepare the crash simulation.\n";
    }
    sqlite3_finalize(statement);
}

