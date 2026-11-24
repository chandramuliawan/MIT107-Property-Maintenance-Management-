const searchBox = document.getElementById("searchBox");

if (searchBox) {

    searchBox.addEventListener("keyup", function () {

        const searchText =
            searchBox.value.toLowerCase();

        const heaterRow =
            document.getElementById("heaterRow");

        const tapRow =
            document.getElementById("tapRow");

        if ("broken heater".includes(searchText)) {
            heaterRow.style.display = "";
        } else {
            heaterRow.style.display =
                searchText === "" ? "" : "none";
        }

        if ("leaking tap".includes(searchText)) {
            tapRow.style.display = "";
        } else {
            tapRow.style.display =
                searchText === "" ? "" : "none";
        }
    });
}
const loginBtn =
    document.getElementById("loginBtn");

if (loginBtn) {

    loginBtn.addEventListener("click",
        function () {

            const email =
                document.getElementById("email").value;

            const password =
                document.getElementById("password").value;

            const loginMessage =
                document.getElementById("loginMessage");

            if (email === "" || password === "") {

                loginMessage.textContent =
                    "Please enter email and password.";

                loginMessage.style.color = "red";

            } else {

                window.location.href =
                    "tenant-dashboard.html";

            }

        });

}
const submitIssueBtn =
    document.getElementById("submitIssueBtn");

if (submitIssueBtn) {

    submitIssueBtn.addEventListener(
        "click",
        function () {

            const issueTitle =
                document.getElementById("issueTitle").value;

            const issueDetails =
                document.getElementById("issueDetails").value;

            const issueMessage =
                document.getElementById("issueMessage");

            if (
                issueTitle === "" ||
                issueDetails === ""
            ) {

                issueMessage.textContent =
                    "Please complete all required fields.";

                issueMessage.style.color = "red";

            } else {

                alert(
                    "Maintenance request submitted successfully!"
                );

                window.location.href =
                    "tenant-dashboard.html";

            }

        }
    );

}
function formatStatus(status) {

    return status.replaceAll("_", " ");

}